#!/usr/bin/env bash
# ===========================================================================
# prueba-restauracion.sh — Borrar datos reales y recuperarlos (§3.2, 2.6).
#
#     P9/scripts/prueba-restauracion.sh
#
# La prueba de DR (`prueba-dr.sh`) pierde el clúster entero. Esta pierde
# SOLO los datos, con el clúster sano: el incidente más común —un `DELETE`
# sin `WHERE`, una migración equivocada— y el que más fácilmente se cree
# cubierto sin estarlo.
#
#   1. Marcas «pre-respaldo» en ops_db.p9_marcas y espera al siguiente
#      respaldo programado: esas marcas DEBEN volver.
#   2. Marcas «post-respaldo»: esas NO pueden volver; contarlas es el RPO.
#   3. Huella completa de las bases (filas + md5 por tabla).
#   4. BORRADO: TRUNCATE de todas las tablas de ops_db y catalog_db.
#   5. Restauración desde el respaldo, con el procedimiento del runbook (§7):
#      pausar ArgoCD → bajar PostgreSQL → borrar su PVC → Velero restaura el
#      PVC desde el snapshot → subir PostgreSQL → reanudar ArgoCD.
#   6. Huella otra vez y comparación tabla por tabla y marca por marca.
#
# Una sonda contra la URL pública mide cuánto estuvo el servicio sin base.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

PVC="data-sa-platform-postgresql-0"
STS="sa-platform-postgresql"
APP_PLATAFORMA="sa-p8-plataforma-prod"
APP_RAIZ="sa-p9-raiz"

iniciar_registro prueba-restauracion
DATOS="${REGISTRO%.log}"; mkdir -p "$DATOS"
marca "prueba" "restauración de datos verificada en ${NS_DATOS} (RPO declarado 15 min)"

credenciales_cluster || fallar "no hay clúster"
apps_sanas || { estado_apps | tee -a "$REGISTRO"; fallar "no todas las Application están Synced/Healthy"; }
crear_tabla_marcas >/dev/null

# --- 1. Marcas que el respaldo tiene que contener ------------------------------
ESCRITAS="$DATOS/marcas-escritas.txt"; : >"$ESCRITAS"
for _ in $(seq 1 10); do insertar_marca prueba-restauracion >>"$ESCRITAS"; sleep 2; done
marca "datos" "10 marcas PRE-respaldo escritas (ids $(head -n1 "$ESCRITAS" | cut -d'|' -f1)–$(tail -n1 "$ESCRITAS" | cut -d'|' -f1))"

previo="$(ultimo_respaldo)"
marca "respaldo" "esperando al siguiente respaldo programado de ${SCHEDULE_VELERO} (≤ 15 min)…"
limite=$(( $(ahora_epoch) + 20 * 60 ))
until [[ "$(ultimo_respaldo)" != "$previo" ]]; do
  (( $(ahora_epoch) < limite )) || fallar "el Schedule no completó un respaldo en 20 min"
  sleep 20
done
read -r R_INICIO RESPALDO <<<"$(ultimo_respaldo)"
marca "respaldo" "respaldo ${RESPALDO} Completed (inicio ${R_INICIO})"
ejecutar "respaldo" "contenido del respaldo" -- \
  velero --kubecontext "$KUBE_CONTEXT" backup describe "$RESPALDO" --details

# --- 2. Marcas que el respaldo NO tiene ----------------------------------------
for _ in $(seq 1 6); do insertar_marca prueba-restauracion >>"$ESCRITAS"; sleep 10; done
marca "datos" "6 marcas POST-respaldo escritas: estas se perderán, y es lo que mide el RPO"

# --- 3. Huella de antes ----------------------------------------------------------
huella_bd >"$DATOS/huella-antes.txt"
marca "datos" "huella antes del borrado:"
sed 's/^/        /' "$DATOS/huella-antes.txt" | tee -a "$REGISTRO"

sonda_iniciar "$DATOS/sonda.txt" /health 2
trap 'sonda_parar "$DATOS/sonda.txt"' EXIT

# --- 4. El borrado ---------------------------------------------------------------
T_BORRADO="$(ahora_iso)"
marca "borrado" "═══ T_borrado = ${T_BORRADO}: TRUNCATE de todas las tablas de ops_db y catalog_db ═══"
for db in ops_db catalog_db; do
  psql_bd "$db" <<'SQL'
DO $$ DECLARE t text; BEGIN
  FOR t IN SELECT format('%I.%I', schemaname, tablename) FROM pg_tables
           WHERE schemaname NOT IN ('pg_catalog', 'information_schema') LOOP
    EXECUTE 'TRUNCATE ' || t || ' CASCADE';
  END LOOP;
END $$;
SQL
done
huella_bd >"$DATOS/huella-borrada.txt"
marca "borrado" "huella después del borrado (los datos ya no están):"
grep -E '^(ops_db|catalog_db)\.' "$DATOS/huella-borrada.txt" | sed 's/^/        /' | tee -a "$REGISTRO"

# --- 5. Restauración (runbook §7) ---------------------------------------------------
marca "restauracion" "1/6 pausar la sincronización automática (raíz y plataforma-prod)"
k -n argocd patch application "$APP_RAIZ" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null
k -n argocd patch application "$APP_PLATAFORMA" --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}' >/dev/null

reanudar() {
  k -n argocd patch application "$APP_RAIZ" --type merge \
    -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}' >/dev/null 2>&1 || true
}
trap 'reanudar; sonda_parar "$DATOS/sonda.txt"' EXIT

marca "restauracion" "2/6 bajar PostgreSQL a 0 réplicas"
k -n "$NS_DATOS" scale statefulset "$STS" --replicas=0 >/dev/null
k -n "$NS_DATOS" wait --for=delete "pod/${POD_PG}" --timeout=180s >/dev/null 2>&1 || true

marca "restauracion" "3/6 borrar el PVC ${PVC} (su disco se va con él)"
k -n "$NS_DATOS" delete pvc "$PVC" --wait=true --timeout=180s >/dev/null

RESTORE="p9-restauracion-$(date -u +%Y%m%d-%H%M%S)"
ejecutar "restauracion" "4/6 velero restore ${RESTORE} desde ${RESPALDO}" -- \
  velero --kubecontext "$KUBE_CONTEXT" restore create "$RESTORE" \
    --from-backup "$RESPALDO" \
    --include-namespaces "$NS_DATOS" \
    --include-resources persistentvolumeclaims,persistentvolumes \
    --restore-volumes=true --wait
fase=$(k -n "$NS_VELERO" get restores.velero.io "$RESTORE" -o jsonpath='{.status.phase}')
marca "restauracion" "Restore ${RESTORE}: ${fase} (el PVC de RabbitMQ ya existía y se omite: es lo esperado)"
[[ "$fase" == "Completed" || "$fase" == "PartiallyFailed" ]] || fallar "restauración en estado ${fase}"
k -n "$NS_DATOS" get pvc | sed 's/^/        /' | tee -a "$REGISTRO"

marca "restauracion" "5/6 subir PostgreSQL y esperar a que acepte conexiones"
k -n "$NS_DATOS" scale statefulset "$STS" --replicas=1 >/dev/null
k -n "$NS_DATOS" wait --for=condition=Ready "pod/${POD_PG}" --timeout=600s >/dev/null
T_DATOS="$(ahora_iso)"
marca "restauracion" "PostgreSQL listo con el volumen restaurado (${T_DATOS})"

marca "restauracion" "6/6 reanudar ArgoCD (la raíz devuelve a la plataforma su política desde Git)"
reanudar
limite=$(( $(ahora_epoch) + 600 ))
until apps_sanas; do (( $(ahora_epoch) < limite )) || break; sleep 10; done
marca "restauracion" "Application: $(apps_sanas && echo 'todas Synced/Healthy' || echo 'NO todas sanas')"

sleep 20
sonda_parar "$DATOS/sonda.txt"; trap - EXIT

# --- 6. Verificación del contenido ------------------------------------------------------
psql_bd ops_db <<'SQL' >"$DATOS/marcas-recuperadas.txt"
SELECT id, to_char(creado AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), contenido
FROM p9_marcas WHERE origen = 'prueba-restauracion' ORDER BY id;
SQL
huella_bd >"$DATOS/huella-despues.txt"

{
  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo " VERIFICACIÓN DEL CONTENIDO RESTAURADO"
  echo "════════════════════════════════════════════════════════════════════"
  echo "Disponibilidad de /health durante el incidente:"
  sonda_resumen "$DATOS/sonda.txt" | sed 's/^/  /'
  echo
  python3 "$DIR/analisis/medir.py" \
    --escritas "$ESCRITAS" \
    --recuperadas "$DATOS/marcas-recuperadas.txt" \
    --sonda "$DATOS/sonda.txt" \
    --desastre "$T_BORRADO" \
    --respaldo "$R_INICIO" \
    --huella-antes "$DATOS/huella-antes.txt" \
    --huella-despues "$DATOS/huella-despues.txt" \
    --rpo-declarado-min 15
  echo
  echo "Marcas, una por una (✓ volvió con el mismo contenido · ✗ perdida):"
  awk -F'|' 'NR==FNR { r[$1]=$3; next } { printf "  %s %5s  %s  %s\n", (($1 in r) && r[$1]==$3 ? "✓" : "✗"), $1, $2, $3 }' \
    "$DATOS/marcas-recuperadas.txt" "$ESCRITAS"
} | tee -a "$REGISTRO"
marca "fin" "prueba de restauración terminada → ${REGISTRO#"${RAIZ}/"}"
