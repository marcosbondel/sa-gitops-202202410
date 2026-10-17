#!/usr/bin/env bash
# Se carga con `source`: las variables se usan en los scripts que la cargan.
# shellcheck disable=SC2034
# ===========================================================================
# lib.sh — Funciones compartidas por los scripts de la Práctica 9.
#
# Se carga con `source` DESPUÉS de `config.sh`.
#
# ## El registro con marcas de tiempo
#
# Toda la práctica se califica con tiempos medidos: el RTO sale de restar dos
# marcas de este registro, y el RPO de comparar una marca con el contenido de
# la base restaurada. Por eso cada línea lleva tres cosas:
#
#     2026-11-20T15:04:05Z  +07:42  [cluster]  clúster creado
#     └── UTC, del reloj ──┘ └ desde ┘ └ etapa ┘
#         de la máquina       el inicio
#
# UTC y no hora local: las marcas de Kubernetes, de Velero y de GCS están en
# UTC, y compararlas con una hora local obligaría a convertir de cabeza
# durante el análisis —y a equivocarse—.
# ===========================================================================

# --- Registro ---------------------------------------------------------------
REGISTRO="${REGISTRO:-}"
T_INICIO="${T_INICIO:-}"

ahora_iso() { date -u +%Y-%m-%dT%H:%M:%SZ; }
ahora_epoch() { date -u +%s; }

# iniciar_registro <nombre>  → docs/evidencias/<nombre>-<UTC>.log
# Si ya hay un registro abierto (REGISTRO exportado por un script padre, como
# `prueba-dr.sh` llamando a `bootstrap.sh`), se reutiliza: una prueba de DR es
# UN registro continuo, no tres archivos que haya que coser a mano.
iniciar_registro() {
  if [[ -z "$REGISTRO" ]]; then
    mkdir -p "$EVIDENCIAS"
    REGISTRO="${EVIDENCIAS}/${1}-$(date -u +%Y%m%dT%H%M%SZ).log"
    T_INICIO="$(ahora_epoch)"
    export REGISTRO T_INICIO
    {
      echo "# ${1} — Práctica 9 (202202410)"
      echo "# inicio:   $(ahora_iso)"
      echo "# máquina:  $(uname -sm) · $(whoami)"
      echo "# cuenta:   ${CUENTA} · proyecto ${PROJECT_ID}"
      echo "# comando:  $0 $*"
      echo "#"
      echo "# Formato:  <UTC>  +<min:seg desde el inicio>  [etapa]  mensaje"
      echo
    } >"$REGISTRO"
  fi
}

transcurrido() {
  local s=$(( $(ahora_epoch) - ${T_INICIO:-$(ahora_epoch)} ))
  printf '+%02d:%02d' $((s / 60)) $((s % 60))
}

# marca <etapa> <mensaje>
marca() {
  local linea
  linea="$(ahora_iso)  $(transcurrido)  [$1]  $2"
  echo "$linea"
  [[ -n "$REGISTRO" ]] && echo "$linea" >>"$REGISTRO"
  return 0
}

# Ejecuta un comando y guarda su salida en el registro, indentada.
# ejecutar <etapa> <descripción> -- <comando...>
ejecutar() {
  local etapa="$1" desc="$2"; shift 3
  marca "$etapa" "▶ $desc"
  local rc=0
  "$@" 2>&1 | sed 's/^/        /' | tee -a "${REGISTRO:-/dev/null}" || rc=${PIPESTATUS[0]}
  if (( rc != 0 )); then
    marca "$etapa" "✗ $desc (código $rc)"
    return "$rc"
  fi
  marca "$etapa" "✓ $desc"
}

fallar() {
  marca "error" "$1"
  exit 1
}

# --- Terraform --------------------------------------------------------------
# tf <dir> <prefijo> <argumentos...>
# Siempre con el backend remoto y sin preguntar: un script que se detiene a
# pedir «yes» no es un punto de entrada único.
tf_init() {
  terraform -chdir="$1" init -input=false -reconfigure -no-color \
    -backend-config="bucket=${BUCKET_TFSTATE}" \
    -backend-config="prefix=${2}" >/dev/null
}

tf_vars_fundacion=(-var="project_id=${PROJECT_ID}" -var="region=${REGION}" -var="zone=${ZONE}"
                   -var="cluster=${CLUSTER}" -var="bucket_respaldos=${BUCKET_VELERO}"
                   -var="secreto_llave_sealed_secrets=${SECRETO_LLAVE}")
tf_vars_cluster=(-var="bucket_tfstate=${BUCKET_TFSTATE}" -var="machine_type=${MACHINE_TYPE}"
                 -var="num_nodes=${NUM_NODES}" -var="disk_type=${DISK_TYPE}" -var="disk_size=${DISK_SIZE}")
tf_vars_gitops=(-var="bucket_tfstate=${BUCKET_TFSTATE}" -var="gitops_url=${GITOPS_URL}"
                -var="gitops_rama=${GITOPS_RAMA}")

tf_salida() { terraform -chdir="$1" output -raw "$2" 2>/dev/null; }

# --- Kubernetes -------------------------------------------------------------
k() { kubectl --context "$KUBE_CONTEXT" "$@"; }

cluster_existe() {
  gcloud container clusters describe "$CLUSTER" --zone "$ZONE" \
    --format='value(status)' 2>/dev/null | grep -q .
}

credenciales_cluster() {
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" >/dev/null 2>&1
}

# Estado de todas las Application en una línea por app.
estado_apps() {
  k -n argocd get applications.argoproj.io \
    -o custom-columns='APP:.metadata.name,OLA:.metadata.annotations.argocd\.argoproj\.io/sync-wave,SYNC:.status.sync.status,SALUD:.status.health.status' \
    --sort-by='.metadata.name' 2>/dev/null
}

# ¿Están TODAS Synced y Healthy? Devuelve 0 si sí.
apps_sanas() {
  local total malas
  total=$(k -n argocd get applications.argoproj.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
  (( total > 0 )) || return 1
  malas=$(k -n argocd get applications.argoproj.io \
    -o jsonpath='{range .items[*]}{.status.sync.status}/{.status.health.status}{"\n"}{end}' 2>/dev/null \
    | grep -vc '^Synced/Healthy$' || true)
  [[ "$malas" == "0" ]]
}

# --- PostgreSQL de producción -------------------------------------------------
NS_DATOS="${NS_DATOS:-$NS_PROD}"
POD_PG="sa-platform-postgresql-0"

# psql_bd <base> < SQL   → filas separadas por `|`, sin cabecera
# El SQL va por la entrada estándar y la contraseña se lee DENTRO del
# contenedor, del archivo que monta el chart: no pasa por la línea de comandos
# de esta máquina ni queda en el historial.
psql_bd() {
  k -n "$NS_DATOS" exec -i "$POD_PG" -c postgresql -- bash -c \
    "PGPASSWORD=\"\$(cat \"\$POSTGRES_PASSWORD_FILE\")\" psql -h 127.0.0.1 -U postgres -d '$1' -At -v ON_ERROR_STOP=1 -q"
}

# La tabla de marcas de la verificación. Vive en `ops_db`, la base de la
# plataforma, al lado de `heartbeats`: no es una base aparte creada para la
# prueba, es la misma que se respalda y se restaura con todo lo demás.
crear_tabla_marcas() {
  psql_bd ops_db <<'SQL'
CREATE TABLE IF NOT EXISTS p9_marcas (
  id        bigserial   PRIMARY KEY,
  creado    timestamptz NOT NULL DEFAULT clock_timestamp(),
  origen    text        NOT NULL,
  contenido text        NOT NULL
);
SQL
}

# insertar_marca <origen> → imprime "id|creado|contenido"
insertar_marca() {
  local contenido
  contenido="${1}-$(date -u +%H%M%S)-${RANDOM}${RANDOM}"
  psql_bd ops_db <<SQL
INSERT INTO p9_marcas (origen, contenido) VALUES ('$1', '$contenido')
RETURNING id, to_char(creado AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), contenido;
SQL
}

# ## La huella de la base de datos
#
# Para cada tabla de cada base `*_db`: número de filas y un md5 de TODAS sus
# filas, ordenadas. Dos huellas iguales significan contenido idéntico fila por
# fila, no solo «el volumen existe» ni «tiene el mismo número de filas».
#
# Es lo que separa el criterio 2.6 —«se verifica su contenido real»— de un
# `ls` sobre el volumen.
huella_bd() {
  k -n "$NS_DATOS" exec -i "$POD_PG" -c postgresql -- bash -s <<'BASH'
export PGPASSWORD="$(cat "$POSTGRES_PASSWORD_FILE")"
P="psql -h 127.0.0.1 -U postgres -At -q"
for db in $($P -d postgres -c "SELECT datname FROM pg_database WHERE datname LIKE '%\_db' ORDER BY 1"); do
  $P -d "$db" -F ' ' <<SQL
SELECT format(
  'SELECT %L, count(*), md5(coalesce(string_agg(t::text, %L ORDER BY t::text), %L)) FROM %I.%I t',
  '$db.' || tablename, '|', '', schemaname, tablename)
FROM pg_tables
WHERE schemaname NOT IN ('pg_catalog', 'information_schema')
ORDER BY tablename
\gexec
SQL
done
BASH
}

# --- HTTP ----------------------------------------------------------------------
ip_publica() {
  gcloud compute addresses describe "${CLUSTER}-ingress" --region "$REGION" \
    --format='value(address)' 2>/dev/null
}

host_prod() { echo "sa-p9.$(ip_publica).nip.io"; }

# El token de Terraform dura una hora; una prueba de DR completa (destruir +
# reconstruir + verificar) puede pasar de eso. Se renueva antes de cada capa.
renovar_token() {
  GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud config config-helper --force-auth-refresh --format='value(credential.access_token)')"
  export GOOGLE_OAUTH_ACCESS_TOKEN
}

# ## La IP retenida por un balanceador huérfano
#
# Si el clúster muere de golpe, la regla de reenvío que GKE creó para el
# Service de ingress-nginx queda viva y SIGUE usando la IP reservada. El
# clúster nuevo pediría esa IP y su Service se quedaría en `<pending>` para
# siempre, sin un error claro. Solo se llama cuando NO hay clúster: con
# clúster vivo, la regla no es huérfana.
liberar_ip_huerfana() {
  local ip nombre region destino
  ip="$(ip_publica)"
  [[ -n "$ip" ]] || return 0
  while read -r nombre region; do
    [[ -n "$nombre" ]] || continue
    destino=$(gcloud compute forwarding-rules describe "$nombre" --region "$region" \
      --format='value(target.basename(),backendService.basename())' 2>/dev/null || true)
    marca "ip" "regla de reenvío huérfana ${nombre} retiene ${ip}: se borra"
    gcloud compute forwarding-rules delete "$nombre" --region "$region" --quiet >/dev/null 2>&1 || true
    for d in $destino; do
      gcloud compute target-pools delete "$d" --region "$region" --quiet >/dev/null 2>&1 \
        || gcloud compute backend-services delete "$d" --region "$region" --quiet >/dev/null 2>&1 || true
    done
    gcloud compute firewall-rules delete "k8s-fw-${nombre}" --quiet >/dev/null 2>&1 || true
  done < <(gcloud compute forwarding-rules list --filter="IPAddress=${ip}" \
             --format='value(name,region.basename())' 2>/dev/null)
}

# Nombre e inicio del respaldo `Completed` más reciente del Schedule:
# "<inicio> <nombre>", o vacío.
ultimo_respaldo() {
  k -n "$NS_VELERO" get backups.velero.io -l "velero.io/schedule-name=${SCHEDULE_VELERO}" \
    -o jsonpath='{range .items[?(@.status.phase=="Completed")]}{.status.startTimestamp}{" "}{.metadata.name}{"\n"}{end}' \
    2>/dev/null | sort | tail -n 1
}

# ## La sonda
#
# Una petición cada pocos segundos a la URL PÚBLICA, por el mismo camino que
# un usuario: balanceador → ingress-nginx → gateway → servicios. Cada
# resultado queda con su hora en un archivo. Es la medida de disponibilidad
# que no depende de lo que diga Kubernetes: un pod `Ready` que no contesta
# cuenta como caída.
#
# sonda_iniciar <archivo> <ruta> <intervalo_s>   → deja SONDA_PID
sonda_iniciar() {
  local archivo="$1" ruta="$2" cada="$3" host ip
  host="$(host_prod)"; ip="$(ip_publica)"
  : >"$archivo"
  (
    while [[ ! -f "${archivo}.parar" ]]; do
      c=$(curl -s -o /dev/null -w '%{http_code} %{time_total}' -m 4 -H "Host: ${host}" "http://${ip}${ruta}" 2>/dev/null || true)
      echo "$(date -u +%Y-%m-%dT%H:%M:%SZ) ${c:-000 0}" >>"$archivo"
      sleep "$cada"
    done
  ) &
  SONDA_PID=$!
}

sonda_parar() {
  touch "${1}.parar"
  wait "${SONDA_PID:-}" 2>/dev/null || true
  rm -f "${1}.parar"
}

# Resumen de un archivo de sonda: total, correctas, fallidas, disponibilidad y
# la racha de fallos más larga (con su inicio y su fin).
sonda_resumen() {
  awk '
    { total++; if ($2 == "200") { ok++; if (enfalla) { if (n > maxn) { maxn = n; ini = desde; fin = hasta } enfalla = 0 } }
      else { fallos++; if (!enfalla) { enfalla = 1; n = 0; desde = $1 } n++; hasta = $1 } }
    END {
      if (enfalla && n > maxn) { maxn = n; ini = desde; fin = hasta }
      printf "peticiones %d · 200: %d · fallidas: %d · disponibilidad %.2f %%\n", total, ok, fallos, (total ? 100 * ok / total : 0)
      if (maxn) printf "racha de fallos más larga: %d peticiones, de %s a %s\n", maxn, ini, fin
      else print "ninguna petición falló"
    }' "$1"
}
