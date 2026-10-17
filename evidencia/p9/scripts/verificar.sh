#!/usr/bin/env bash
# ===========================================================================
# verificar.sh — ¿Está el sistema recuperado DE VERDAD?
#
#     P9/scripts/verificar.sh
#
# Lo corre `prueba-dr.sh` al final, lo pide el runbook como último paso, y es
# lo primero que conviene enseñar al iniciar la calificación (§8.1: «sistema
# desplegado y sincronizado», «al menos un respaldo completado, verificable
# en el momento»).
#
# Cada comprobación imprime ✓ o ✗ con el dato que la respalda. Sale con
# código distinto de cero si alguna falla.
# ===========================================================================
set -uo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh" >/dev/null
# shellcheck source=lib.sh
source "$DIR/lib.sh"

credenciales_cluster || { echo "✗ no hay clúster ${CLUSTER}"; exit 1; }
FALLOS=0
ok()  { printf '  ✓ %s\n' "$1"; }
mal() { printf '  ✗ %s\n' "$1"; FALLOS=$((FALLOS + 1)); }
sec() { printf '\n%s\n' "$1"; }

# --- GitOps ------------------------------------------------------------------------
sec "GitOps — ArgoCD (app-of-apps)"
raiz=$(k -n argocd get application sa-p9-raiz -o jsonpath='{.status.sync.status}/{.status.health.status}' 2>/dev/null)
[[ "$raiz" == "Synced/Healthy" ]] && ok "raíz sa-p9-raiz (namespace argocd): ${raiz}" || mal "raíz sa-p9-raiz: ${raiz:-no existe}"
n=$(k -n argocd get applications.argoproj.io --no-headers 2>/dev/null | wc -l | tr -d ' ')
apps_sanas && ok "las ${n} Application están Synced/Healthy" || mal "no todas las Application están Synced/Healthy"
estado_apps | sed 's/^/      /'
rev=$(k -n argocd get application sa-p9-raiz -o jsonpath='{.status.sync.revision}' 2>/dev/null)
ok "revisión del repositorio GitOps desplegada: ${rev:0:12}"

# --- Secretos -------------------------------------------------------------------------
sec "Continuidad de los secretos — Sealed Secrets"
huella() { openssl x509 -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }
h_cluster=$(kubeseal --context "$KUBE_CONTEXT" --controller-name sealed-secrets-controller \
  --controller-namespace kube-system --fetch-cert 2>/dev/null | huella)
h_sm=$(gcloud secrets versions access latest --secret "$SECRETO_LLAVE" 2>/dev/null | jq -r '."tls.crt"' | huella)
h_repo=$(curl -fsSL "https://raw.githubusercontent.com/marcosbondel/sa-gitops-202202410/${GITOPS_RAMA}/sealed-secrets/clave-publica.pem" 2>/dev/null | huella)
echo "      controlador en el clúster  ${h_cluster:-?}"
echo "      Secret Manager             ${h_sm:-?}"
echo "      repositorio GitOps         ${h_repo:-?}"
[[ -n "$h_cluster" && "$h_cluster" == "$h_sm" && "$h_sm" == "$h_repo" ]] \
  && ok "la llave del clúster es la de Secret Manager y la del repositorio" \
  || mal "las huellas de la llave no coinciden"
total=$(k get sealedsecrets.bitnami.com -A --no-headers 2>/dev/null | wc -l | tr -d ' ')
abiertos=$(k get sealedsecrets.bitnami.com -A -o jsonpath='{range .items[*]}{.status.conditions[?(@.type=="Synced")].status}{"\n"}{end}' 2>/dev/null | grep -c True)
ausentes=0
while read -r ns nombre; do
  k -n "$ns" get secret "$nombre" >/dev/null 2>&1 || ausentes=$((ausentes + 1))
done < <(k get sealedsecrets.bitnami.com -A -o jsonpath='{range .items[*]}{.metadata.namespace}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null)
(( total > 0 && abiertos == total && ausentes == 0 )) \
  && ok "${abiertos}/${total} SealedSecret descifrados; los ${total} Secret existen" \
  || mal "SealedSecret descifrados: ${abiertos}/${total}; Secret ausentes: ${ausentes}"

# --- Respaldos -------------------------------------------------------------------------
sec "Respaldos — Velero"
bsl=$(k -n "$NS_VELERO" get backupstoragelocations.velero.io default -o jsonpath='{.status.phase} · gs://{.spec.objectStorage.bucket}' 2>/dev/null)
[[ "$bsl" == Available* ]] && ok "destino: ${bsl}" || mal "destino: ${bsl:-no existe}"
sch=$(k -n "$NS_VELERO" get schedules.velero.io "$SCHEDULE_VELERO" -o jsonpath='{.spec.schedule} · TTL {.spec.template.ttl} · {.status.phase}' 2>/dev/null)
[[ -n "$sch" ]] && ok "Schedule ${SCHEDULE_VELERO}: ${sch}" || mal "no existe el Schedule ${SCHEDULE_VELERO}"
read -r ult_ini ult_nom <<<"$(ultimo_respaldo)"
if [[ -n "${ult_nom:-}" ]]; then
  edad=$(( $(ahora_epoch) - $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$ult_ini" +%s 2>/dev/null || date -u -d "$ult_ini" +%s) ))
  vols=$(k -n "$NS_VELERO" get backups.velero.io "$ult_nom" -o jsonpath='{.status.volumeSnapshotsCompleted}/{.status.volumeSnapshotsAttempted}')
  # Justo después de reconstruir, el Schedule recién creado aún no llegó a su
  # primer tic (≤ 15 min): el respaldo más reciente es el del clúster
  # anterior. Eso no es un fallo mientras el Schedule tenga < 20 min.
  edad_sch=$(( $(ahora_epoch) - $(date -j -u -f '%Y-%m-%dT%H:%M:%SZ' "$(k -n "$NS_VELERO" get schedules.velero.io "$SCHEDULE_VELERO" -o jsonpath='{.metadata.creationTimestamp}')" +%s 2>/dev/null || ahora_epoch) ))
  if (( edad < 20 * 60 )); then
    ok "último respaldo Completed: ${ult_nom} (hace $((edad / 60)) min; snapshots ${vols})"
  elif (( edad_sch < 20 * 60 )); then
    ok "último respaldo Completed: ${ult_nom} (hace $((edad / 60)) min, del clúster anterior; el Schedule se creó hace $((edad_sch / 60)) min y su primer respaldo llega en ≤ 15 min)"
  else
    mal "el último respaldo Completed tiene $((edad / 60)) min (${ult_nom})"
  fi
else
  mal "no hay ningún respaldo Completed"
fi
k -n "$NS_VELERO" get backups.velero.io -l "velero.io/schedule-name=${SCHEDULE_VELERO}" --sort-by=.metadata.creationTimestamp \
  -o custom-columns='RESPALDO:.metadata.name,FASE:.status.phase,INICIO:.status.startTimestamp,SNAPSHOTS:.status.volumeSnapshotsCompleted,EXPIRA:.status.expiration' 2>/dev/null \
  | tail -n 6 | sed 's/^/      /'
res=$(k -n "$NS_VELERO" get configmap "$CM_RESULTADO_RESTAURACION" -o jsonpath='{.data.estado}: {.data.detalle}' 2>/dev/null)
ok "Job de restauración del arranque — ${res:-sin resultado}"

# --- Flujo de la P8 -------------------------------------------------------------------------
sec "Flujo de la Práctica 8 tras la reconstrucción"
pol=$(k get clusterpolicies.kyverno.io -o jsonpath='{range .items[*]}{.metadata.name}={.status.conditions[?(@.type=="Ready")].status}{"\n"}{end}' 2>/dev/null)
listas=$(grep -c '=True' <<<"$pol")
(( listas >= 4 )) && ok "${listas} ClusterPolicy de Kyverno Ready ($(cut -d= -f1 <<<"$pol" | paste -sd ', ' -))" || mal "ClusterPolicy Ready: ${listas}"
rechazo=$(k -n "$NS_STAGE" run p9-prueba-politica --image=nginx:latest --dry-run=server -o name 2>&1 || true)
grep -qiE 'denied|blocked|violat|prohib' <<<"$rechazo" \
  && ok "admisión: un pod con :latest es RECHAZADO ($(grep -oiE 'prohibir-latest|[a-z-]*latest[a-z-]*' <<<"$rechazo" | head -n1))" \
  || mal "admisión: el pod con :latest NO fue rechazado"
ro=$(k -n "$NS_PROD" get rollouts.argoproj.io -o jsonpath='{range .items[*]}{.metadata.name} {.status.phase} {.status.stableRS}{"\n"}{end}' 2>/dev/null)
[[ -n "$ro" ]] && ! grep -qvE ' Healthy ' <<<"$ro" \
  && ok "Rollouts de producción Healthy: $(awk '{print $1}' <<<"$ro" | paste -sd ', ' -)" \
  || mal "Rollouts: ${ro:-ninguno}"
img=$(k -n "$NS_PROD" get rollouts.argoproj.io sa-platform-api-gateway -o jsonpath='{.spec.template.spec.containers[0].image}' 2>/dev/null)
ok "imagen del gateway (firmada, verificada por Kyverno al admitir): ${img:-?}"

# --- El servicio y sus datos ------------------------------------------------------------------
sec "Servicio y datos"
HOST="$(host_prod)"; IP="$(ip_publica)"
c=$(curl -s -o /dev/null -w '%{http_code}' -m 10 -H "Host: ${HOST}" "http://${IP}/health")
[[ "$c" == "200" ]] && ok "http://${HOST}/health → 200 (público, sin autenticación de clúster)" || mal "http://${HOST}/health → ${c}"
hb=$(psql_bd ops_db <<<"SELECT count(*) || ' latidos · último ' || to_char(max(executed_at) AT TIME ZONE 'UTC', 'YYYY-MM-DD HH24:MI:SS') || 'Z' FROM heartbeats" 2>/dev/null)
[[ -n "$hb" ]] && ok "ops_db.heartbeats: ${hb}" || mal "no se pudo leer ops_db.heartbeats"
mk=$(psql_bd ops_db <<<"SELECT count(*) FROM p9_marcas" 2>/dev/null || echo 0)
ok "ops_db.p9_marcas: ${mk} marcas de las pruebas"

echo
if (( FALLOS == 0 )); then echo "RESULTADO: todo verificado ✓"; else echo "RESULTADO: ${FALLOS} comprobaciones fallaron ✗"; fi
exit "$FALLOS"
