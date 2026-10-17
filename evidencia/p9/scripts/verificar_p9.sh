#!/usr/bin/env bash
# =============================================================================
#  verificar_p9.sh  (calificacion PRESENCIAL)
#  Software Avanzado - Segundo Semestre 2026
#  Practica 9: Continuidad Operativa y Recuperacion ante Desastres
#
#  Se ejecuta EN LA MAQUINA DEL ESTUDIANTE, con su contexto de kubectl.
#
#  PREPARACION (el estudiante, antes de la calificacion):
#     ./verificar_p9.sh --init      # genera la plantilla p9.conf
#     nano p9.conf                  # llena los datos
#     ./verificar_p9.sh             # corrige lo que salga en rojo
#
#  CALIFICACION (el auxiliar):
#     sha256sum verificar_p9.sh     # comparar con el hash publicado
#     ./verificar_p9.sh
#
#  Requiere: git jq kubectl velero argocd helm terraform
# =============================================================================

set -uo pipefail

VERSION="1.0"
CONF="p9.conf"

if [ "${1:-}" = "--init" ]; then
  if [ -f "$CONF" ]; then echo "Ya existe $CONF."; exit 1; fi
  cat > "$CONF" <<'PLANTILLA'
# Datos de la entrega de la Practica 9.
# Deben coincidir EXACTAMENTE con la tabla 4.1 del README de su entrega.

CARNET="202012345"
REPO_CODE="https://github.com/usuario/software-avanzado"
REPO_GITOPS="https://github.com/usuario/software-avanzado-gitops"

APP_ROOT="raiz"              # aplicacion app-of-apps en ArgoCD
NS="produccion"              # namespace de la aplicacion
NS_VELERO="velero"           # namespace donde vive Velero

BOOTSTRAP="P9/bootstrap.sh"  # punto de entrada unico, relativo al repo de codigo
PVC="datos-postgres"         # PVC con los datos que se restauran
PLANTILLA
  echo "Creado $CONF. Llenelo y vuelva a ejecutar el script sin argumentos."
  exit 0
fi

[ -f "$CONF" ] || { echo "ERROR: falta $CONF. Ejecute: ./verificar_p9.sh --init"; exit 1; }
# shellcheck disable=SC1090
source "./$CONF"

: "${CARNET:?Falta CARNET}"; : "${REPO_CODE:?Falta REPO_CODE}"
: "${REPO_GITOPS:?Falta REPO_GITOPS}"; : "${APP_ROOT:?Falta APP_ROOT}"
: "${NS:?Falta NS}"
NS_VELERO="${NS_VELERO:-velero}"
BOOTSTRAP="${BOOTSTRAP:-}"
PVC="${PVC:-}"

WORK=$(mktemp -d /tmp/p9_XXXXXX)
REPORTE="reporte_p9_${CARNET}.txt"
CSV="resultados_p9.csv"
INICIO=$(date +%s)

if [ -t 1 ]; then V='\033[0;32m'; R='\033[0;31m'; A='\033[0;33m'; N='\033[0m'
else V=''; R=''; A=''; N=''; fi
exec > >(tee "$REPORTE") 2>&1

ok()  { printf "  ${V}[OK]${N}    %s\n" "$1"; }
bad() { printf "  ${R}[FALLA]${N} %s\n" "$1"; }
avi() { printf "  ${A}[AVISO]${N} %s\n" "$1"; }
sec() { echo ""; echo "--- $1"; }

BO=0; ES=0; VE=0; SE=0; RE=0; DA=0
ELIM=""

echo "================================================================"
echo " VERIFICACION PRACTICA 9 - v$VERSION"
echo " Carnet: $CARNET        Fecha: $(date '+%Y-%m-%d %H:%M')"
echo " Hash del script: $(sha256sum "$0" 2>/dev/null | cut -c1-16)"
echo "================================================================"

# ---------------------------------------------------------------------------
sec "0. Herramientas y contexto (debe verificarlo el auxiliar)"
FALTAN=""
for t in git jq kubectl helm terraform velero; do
  command -v "$t" >/dev/null 2>&1 || FALTAN="$FALTAN $t"
done
[ -n "$FALTAN" ] && avi "Herramientas ausentes:$FALTAN" || ok "Todas las herramientas presentes"
case "$FALTAN" in *velero*) bad "  velero: NO se puede calificar 2.3 ni 2.6 por CLI";; esac
echo "  Contexto de kubectl: $(kubectl config current-context 2>/dev/null || echo 'ninguno')"
kubectl get ns >/dev/null 2>&1 && ok "Acceso al cluster confirmado" \
  || { bad "SIN ACCESO AL CLUSTER"; ELIM="$ELIM sin-cluster"; }

# ---------------------------------------------------------------------------
sec "1. Repositorios"
git clone --quiet --depth 1 "$REPO_CODE" "$WORK/code" 2>/dev/null \
  && ok "Repositorio de codigo accesible" \
  || { bad "Repositorio de codigo INACCESIBLE"; ELIM="$ELIM repo-codigo"; }
git clone --quiet --depth 1 "$REPO_GITOPS" "$WORK/gitops" 2>/dev/null \
  && ok "Repositorio GitOps accesible" \
  || { bad "Repositorio GitOps INACCESIBLE"; ELIM="$ELIM repo-gitops"; }
CODE="$WORK/code"; GITOPS="$WORK/gitops"; P9="$CODE/P9"
[ -d "$P9" ] && ok "Carpeta /P9 presente" || bad "No existe la carpeta /P9"
[ -f "$P9/README.md" ] && ok "README de entrega presente" \
  || { bad "README de entrega AUSENTE"; ELIM="$ELIM readme"; }

# ---------------------------------------------------------------------------
sec "2.1 Bootstrap automatizado desde cero (14 pts)"
if [ -n "$BOOTSTRAP" ] && [ -f "$CODE/$BOOTSTRAP" ]; then
  ok "Punto de entrada presente: $BOOTSTRAP"; BO=$((BO+3))
  PASOS=$(grep -cE '^[^#]*\b(terraform|kubectl|helm|argocd)\b' "$CODE/$BOOTSTRAP" 2>/dev/null || echo 0)
  echo "  Pasos automatizados detectados en el bootstrap: $PASOS"
  grep -qiE 'manual|a mano|hacer.*a mano|TODO' "$CODE/$BOOTSTRAP" 2>/dev/null \
    && avi "El bootstrap menciona pasos manuales: revisar en la demostracion"
else
  bad "No se encuentra el punto de entrada declarado ($BOOTSTRAP)"
fi
grep -rqE 'resource[[:space:]]+"helm_release"[[:space:]]+"(argo-?cd|argocd)"|chart[[:space:]]*=[[:space:]]*"argo-cd"' "$CODE" 2>/dev/null \
  && { ok "Terraform instala ArgoCD (capa de plataforma)"; BO=$((BO+3)); } \
  || bad "No se evidencia la instalacion de ArgoCD desde Terraform"
NAPPS=$(kubectl get applications -n argocd -o name 2>/dev/null | wc -l)
echo "  Aplicaciones registradas en ArgoCD: $NAPPS"
ROOTJSON=$(kubectl get application "$APP_ROOT" -n argocd -o json 2>/dev/null)
if [ -n "$ROOTJSON" ]; then
  NHIJAS=$(echo "$ROOTJSON" | jq '[.status.resources[]? | select(.kind=="Application")] | length')
  SYNCR=$(echo "$ROOTJSON" | jq -r '.status.sync.status // "?"')
  echo "  Aplicacion raiz '$APP_ROOT': sync=$SYNCR  aplicaciones hijas=$NHIJAS"
  if [ "${NHIJAS:-0}" -ge 2 ]; then
    ok "Patron app-of-apps operativo"; BO=$((BO+5))
  else
    bad "La aplicacion raiz no gestiona otras Applications (app-of-apps ausente)"
  fi
  [ "$SYNCR" = "Synced" ] && { ok "Aplicacion raiz sincronizada"; BO=$((BO+3)); } \
    || { bad "Aplicacion raiz NO sincronizada"; ELIM="$ELIM raiz-no-synced"; }
else
  kubectl get applicationsets -A -o name 2>/dev/null | grep -q . \
    && { avi "No existe '$APP_ROOT' pero si un ApplicationSet: verificar en la demostracion"; BO=$((BO+4)); } \
    || { bad "No existe la aplicacion raiz '$APP_ROOT' ni ningun ApplicationSet"; ELIM="$ELIM sin-app-raiz"; }
fi
echo "  >> 2.1 = $BO / 14"

# ---------------------------------------------------------------------------
sec "2.2 Estado remoto y disciplina de IaC (8 pts)"
if grep -rqE 'backend[[:space:]]+"(s3|gcs|azurerm|remote|http|kubernetes|consul)"' "$CODE" 2>/dev/null; then
  ok "Backend remoto declarado: $(grep -rhoE 'backend[[:space:]]+"[a-z0-9]+"' "$CODE" 2>/dev/null | head -1)"
  ES=$((ES+4))
else
  bad "Sin backend remoto declarado en Terraform"; ELIM="$ELIM estado-local"
fi
grep -rqE 'dynamodb_table|use_lockfile|lock' "$CODE" 2>/dev/null \
  && { ok "Se evidencia bloqueo de estado"; ES=$((ES+1)); } \
  || avi "No se evidencia bloqueo explicito (algunos backends lo traen integrado)"
if find "$CODE" -name '*.tfstate*' 2>/dev/null | grep -q .; then
  bad "ARCHIVO DE ESTADO versionado en el repositorio:"
  find "$CODE" -name '*.tfstate*' | sed "s|$CODE/|         |"
  ELIM="$ELIM tfstate-en-repo"
else
  ok "Sin archivos de estado en el repositorio"; ES=$((ES+2))
fi
if grep -rqE '(access_key|secret_key|AKIA[0-9A-Z]{16}|private_key)[[:space:]]*=' "$CODE" 2>/dev/null; then
  bad "POSIBLES CREDENCIALES en el codigo de Terraform"; ELIM="$ELIM credenciales"
else
  ok "Sin credenciales evidentes en el codigo"; ES=$((ES+1))
fi
echo "  >> 2.2 = $ES / 8"

# ---------------------------------------------------------------------------
sec "2.3 Respaldo y restauracion con Velero (14 pts)"
if kubectl get deploy -n "$NS_VELERO" -o name 2>/dev/null | grep -q velero; then
  ok "Velero instalado en el namespace $NS_VELERO"; VE=$((VE+2))
else
  bad "Velero NO esta instalado"
fi
SCHED=$(kubectl get schedules -n "$NS_VELERO" -o json 2>/dev/null)
NSCH=$(echo "${SCHED:-{}}" | jq '[.items[]?] | length' 2>/dev/null || echo 0)
if [ "${NSCH:-0}" -ge 1 ]; then
  ok "Respaldo programado ($NSCH schedule)"; VE=$((VE+3))
  echo "$SCHED" | jq -r 2>/dev/null '.items[]? | "  schedule=\(.metadata.name) cron=\(.spec.schedule) ttl=\(.spec.template.ttl // "sin ttl")"'
  echo "$SCHED" | jq -e '.items[]?.spec.template.ttl' >/dev/null 2>&1 \
    && { ok "Politica de retencion declarada (ttl)"; VE=$((VE+2)); } \
    || bad "Sin politica de retencion (ttl) en el schedule"
else
  bad "Sin respaldos programados: solo respaldos manuales"
fi
BK=$(kubectl get backups -n "$NS_VELERO" -o json 2>/dev/null)
NOK=$(echo "${BK:-{}}" | jq '[.items[]? | select(.status.phase=="Completed")] | length' 2>/dev/null || echo 0)
if [ "${NOK:-0}" -ge 1 ]; then
  ok "$NOK respaldo(s) completado(s)"; VE=$((VE+3))
  echo "$BK" | jq -r 2>/dev/null '[.items[]? | select(.status.phase=="Completed")] | sort_by(.status.completionTimestamp) | last
    | "  ultimo=\(.metadata.name) completado=\(.status.completionTimestamp) items=\(.status.progress.itemsBackedUp // "?")"'
else
  bad "Ningun respaldo completado"; ELIM="$ELIM sin-respaldo"
fi
BSL=$(kubectl get backupstoragelocations -n "$NS_VELERO" -o json 2>/dev/null)
echo "${BSL:-{}}" | jq -r 2>/dev/null '.items[]? | "  destino: provider=\(.spec.provider) bucket=\(.spec.objectStorage.bucket // "?") estado=\(.status.phase // "?")"' 2>/dev/null
echo "${BSL:-{}}" | jq -e '.items[]? | select(.spec.provider != "" and (.spec.objectStorage.bucket // "") != "")' >/dev/null 2>&1 \
  && { ok "Destino de respaldo externo configurado"; VE=$((VE+2)); } \
  || bad "Destino de respaldo no configurado o interno al cluster"
echo "${BK:-{}}" | jq -e '.items[]? | select((.spec.defaultVolumesToFsBackup == true) or (.spec.snapshotVolumes == true) or (.status.volumeSnapshotsAttempted // 0) > 0)' >/dev/null 2>&1 \
  && { ok "Los respaldos incluyen volumenes persistentes"; VE=$((VE+2)); } \
  || bad "Los respaldos NO incluyen volumenes: se respalda solo la definicion"
echo "  >> 2.3 = $VE / 14"

# ---------------------------------------------------------------------------
sec "2.4 Continuidad de los secretos (8 pts)"
MECANISMO=""
grep -rqE 'kind:[[:space:]]*SealedSecret' "$GITOPS" 2>/dev/null && MECANISMO="SealedSecrets"
grep -rqE 'kind:[[:space:]]*(ExternalSecret|ClusterSecretStore|SecretStore)' "$GITOPS" 2>/dev/null && MECANISMO="ExternalSecrets"
if [ -n "$MECANISMO" ]; then
  ok "Mecanismo de secretos: $MECANISMO"; SE=$((SE+2))
else
  bad "Sin SealedSecrets ni ExternalSecrets en el repositorio GitOps"
fi
if [ "$MECANISMO" = "ExternalSecrets" ]; then
  kubectl get clustersecretstores -o name 2>/dev/null | grep -q . \
    && { ok "ClusterSecretStore activo: la llave vive fuera del cluster"; SE=$((SE+4)); } \
    || bad "Sin ClusterSecretStore activo"
  kubectl get externalsecrets -A -o json 2>/dev/null \
    | jq -e '[.items[]? | select(.status.conditions[]?.status=="True")] | length >= 1' >/dev/null 2>&1 \
    && { ok "ExternalSecret sincronizado correctamente"; SE=$((SE+2)); } \
    || bad "Ningun ExternalSecret en estado sincronizado"
else
  # SealedSecrets: la llave debe estar respaldada FUERA del cluster
  if grep -rqiE 'sealed[-_]?secrets?.*(key|llave).*(backup|respaldo)|respaldo.*llave' "$P9" 2>/dev/null; then
    ok "El procedimiento de respaldo de la llave esta documentado"; SE=$((SE+3))
  else
    bad "No se documenta el respaldo de la llave de Sealed Secrets"
    avi "Si se pierde esa llave, el repositorio queda lleno de secretos ilegibles"
  fi
  echo "${BK:-{}}" | jq -e '.items[]? | select((.spec.includedNamespaces // []) | index("kube-system") or index("sealed-secrets"))' >/dev/null 2>&1 \
    && { ok "El respaldo de Velero incluye el namespace de la llave"; SE=$((SE+3)); } \
    || bad "El respaldo no cubre el namespace donde vive la llave"
fi
echo "  >> 2.4 = $SE / 8"

# ---------------------------------------------------------------------------
sec "2.5 Resiliencia ante perdida de nodo (8 pts)"
NPDB=$(kubectl get pdb -n "$NS" -o name 2>/dev/null | wc -l)
[ "$NPDB" -ge 1 ] && { ok "PodDisruptionBudget definido ($NPDB)"; RE=$((RE+3)); } \
                  || bad "Sin PodDisruptionBudget en el namespace $NS"
kubectl get pdb -n "$NS" -o json 2>/dev/null \
  | jq -r 2>/dev/null '.items[]? | "  pdb=\(.metadata.name) minAvailable=\(.spec.minAvailable // "-") maxUnavailable=\(.spec.maxUnavailable // "-") saludables=\(.status.currentHealthy // "?")"'
grep -rqE 'podAntiAffinity|topologySpreadConstraints' "$GITOPS" 2>/dev/null \
  && { ok "Anti-afinidad o distribucion topologica declarada"; RE=$((RE+3)); } \
  || bad "Sin anti-afinidad ni topologySpreadConstraints"
MINREP=$(kubectl get deploy,rollout,statefulset -n "$NS" -o json 2>/dev/null \
         | jq '[.items[]?.spec.replicas // 1] | min' 2>/dev/null || echo 0)
echo "  Replicas minimas entre las cargas de trabajo: ${MINREP:-?}"
[ "${MINREP:-0}" -ge 2 ] 2>/dev/null && { ok "Toda carga de trabajo tiene 2 o mas replicas"; RE=$((RE+2)); } \
                                     || bad "Existe al menos una carga de trabajo con una sola replica"
echo "  >> 2.5 = $RE / 8"

# ---------------------------------------------------------------------------
sec "2.6 Restauracion de datos verificada (8 pts)"
if [ -n "$PVC" ] && kubectl get pvc "$PVC" -n "$NS" >/dev/null 2>&1; then
  FASE=$(kubectl get pvc "$PVC" -n "$NS" -o jsonpath='{.status.phase}')
  ok "PVC '$PVC' presente (fase=$FASE)"; DA=$((DA+2))
else
  NPVC=$(kubectl get pvc -n "$NS" -o name 2>/dev/null | wc -l)
  [ "$NPVC" -ge 1 ] && { avi "No existe '$PVC' pero hay $NPVC PVC en el namespace"; DA=$((DA+1)); } \
                    || bad "Sin volumenes persistentes en el namespace $NS"
fi
RS=$(kubectl get restores -n "$NS_VELERO" -o json 2>/dev/null)
NRS=$(echo "${RS:-{}}" | jq '[.items[]? | select(.status.phase=="Completed" or .status.phase=="PartiallyFailed")] | length' 2>/dev/null || echo 0)
if [ "${NRS:-0}" -ge 1 ]; then
  ok "$NRS restauracion(es) ejecutada(s)"; DA=$((DA+3))
  echo "${RS}" | jq -r 2>/dev/null '.items[]? | "  restore=\(.metadata.name) fase=\(.status.phase) desde=\(.spec.backupName)"'
  echo "${RS}" | jq -e '.items[]? | select(.status.phase=="PartiallyFailed")' >/dev/null 2>&1 \
    && avi "Alguna restauracion quedo parcialmente fallida: preguntar por que"
else
  bad "Nunca se ha ejecutado una restauracion: el respaldo no esta probado"
fi
if find "$P9" -iname '*restaur*' -o -iname '*verificacion*' -o -iname '*evidencia*' 2>/dev/null | grep -q .; then
  ok "Evidencia de verificacion de datos presente en el repositorio"; DA=$((DA+3))
else
  bad "Sin evidencia de verificacion del contenido restaurado"
  avi "Un volumen restaurado vacio no es una restauracion"
fi
echo "  >> 2.6 = $DA / 8"

# ---------------------------------------------------------------------------
sec "Comprobaciones informativas"
find "$P9" -iname '*runbook*' 2>/dev/null | grep -q . \
  && ok "Runbook presente en el repositorio" || bad "No se encuentra el runbook"
grep -rqiE 'RTO|RPO' "$P9" 2>/dev/null \
  && ok "El informe declara RTO y RPO" || bad "No se declaran RTO ni RPO"
kubectl get events -n "$NS" --sort-by=.lastTimestamp 2>/dev/null | tail -5

# ---------------------------------------------------------------------------
TOTAL=$((BO + ES + VE + SE + RE + DA))
DUR=$(( $(date +%s) - INICIO ))
echo ""
echo "================================================================"
echo " RESUMEN - carnet $CARNET"
echo "================================================================"
printf "  2.1 Bootstrap automatizado ....... %2d / 14\n" "$BO"
printf "  2.2 Estado remoto e IaC .......... %2d / 8\n"  "$ES"
printf "  2.3 Respaldo con Velero .......... %2d / 14\n" "$VE"
printf "  2.4 Continuidad de secretos ...... %2d / 8\n"  "$SE"
printf "  2.5 Resiliencia ante fallo ....... %2d / 8\n"  "$RE"
printf "  2.6 Restauracion verificada ...... %2d / 8\n"  "$DA"
echo   "  --------------------------------------------"
printf "  CONOCIMIENTO ..................... %2d / 60\n" "$TOTAL"
echo ""
echo "  Pendiente de evaluacion presencial: 40 pts"
echo "    1.1 Runbook (12)   1.2 Informe de DR (12)"
echo "    1.3 Diagrama del bootstrap (6)   1.4 Preguntas teoricas (10)"
echo ""
if [ -n "$ELIM" ]; then
  printf "  ${R}REQUISITOS ELIMINATORIOS INCUMPLIDOS:${N}%s\n" "$ELIM"
else
  printf "  ${V}Requisitos eliminatorios: todos cumplidos${N}\n"
fi
echo ""
echo "  Duracion: ${DUR}s    Reporte: $REPORTE"
echo "================================================================"

[ -f "$CSV" ] || echo "carnet,bootstrap,estado,velero,secretos,resiliencia,datos,total60,eliminatorios" > "$CSV"
echo "$CARNET,$BO,$ES,$VE,$SE,$RE,$DA,$TOTAL,\"${ELIM:-ninguno}\"" >> "$CSV"
rm -rf "$WORK"
