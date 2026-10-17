#!/usr/bin/env bash
# =============================================================================
#  verificar_p10.sh  (calificacion PRESENCIAL)
#  Software Avanzado - Segundo Semestre 2026
#  Practica 10: Observabilidad y Operacion
#
#  Se ejecuta EN LA MAQUINA DEL ESTUDIANTE, con su contexto de kubectl.
#
#  PREPARACION (el estudiante, antes de la calificacion):
#     ./verificar_p10.sh --init     # genera la plantilla p10.conf
#     nano p10.conf                 # llena los nombres de SUS recursos
#     ./verificar_p10.sh            # corrige lo que salga en rojo
#
#  CALIFICACION (el auxiliar):
#     sha256sum verificar_p10.sh    # comparar con el hash publicado
#     ./verificar_p10.sh
#
#  Requiere: git jq kubectl curl
# =============================================================================

set -uo pipefail

VERSION="1.0"
CONF="p10.conf"

if [ "${1:-}" = "--init" ]; then
  if [ -f "$CONF" ]; then echo "Ya existe $CONF."; exit 1; fi
  cat > "$CONF" <<'PLANTILLA'
# Datos de la entrega de la Practica 10.
# Deben coincidir EXACTAMENTE con la tabla 4.1 del README de su entrega.

CARNET="202012345"
REPO_CODE="https://github.com/usuario/software-avanzado"
REPO_GITOPS="https://github.com/usuario/software-avanzado-gitops"

NS="produccion"                 # namespace de la aplicacion
NS_OBS="observabilidad"         # namespace del stack de observabilidad
ROLLOUT="orders"                # nombre del Rollout gobernado por metricas

# Los tres servicios instrumentados, separados por espacios.
SERVICIOS="orders payments inventory"

# Servicio de Prometheus dentro de NS_OBS y su puerto.
PROM_SVC="prometheus-operated"
PROM_PORT="9090"

# Nombre EXACTO de una metrica de negocio que usted expone.
METRICA_NEGOCIO="pedidos_creados_total"

# Nombre EXACTO de la regla de registro que calcula su indicador (SLI).
REGLA_SLI="sli:disponibilidad:ratio_rate5m"

# Un pod cuyos registros deben salir en JSON (prefijo del nombre).
POD_LOGS="orders"
PLANTILLA
  echo "Creado $CONF. Llenelo y vuelva a ejecutar el script sin argumentos."
  exit 0
fi

[ -f "$CONF" ] || { echo "ERROR: falta $CONF. Ejecute: ./verificar_p10.sh --init"; exit 1; }
# shellcheck disable=SC1090
source "./$CONF"

: "${CARNET:?Falta CARNET}"; : "${REPO_CODE:?Falta REPO_CODE}"
: "${REPO_GITOPS:?Falta REPO_GITOPS}"; : "${NS:?Falta NS}"
NS_OBS="${NS_OBS:-observabilidad}"; ROLLOUT="${ROLLOUT:-}"
SERVICIOS="${SERVICIOS:-}"; PROM_SVC="${PROM_SVC:-prometheus-operated}"
PROM_PORT="${PROM_PORT:-9090}"; METRICA_NEGOCIO="${METRICA_NEGOCIO:-}"
REGLA_SLI="${REGLA_SLI:-}"; POD_LOGS="${POD_LOGS:-}"

WORK=$(mktemp -d /tmp/p10_XXXXXX)
REPORTE="reporte_p10_${CARNET}.txt"
CSV="resultados_p10.csv"
INICIO=$(date +%s)
PF_PID=""

limpiar() { [ -n "$PF_PID" ] && kill "$PF_PID" 2>/dev/null; rm -rf "$WORK"; }
trap limpiar EXIT

if [ -t 1 ]; then V='\033[0;32m'; R='\033[0;31m'; A='\033[0;33m'; N='\033[0m'
else V=''; R=''; A=''; N=''; fi
exec > >(tee "$REPORTE") 2>&1

ok()  { printf "  ${V}[OK]${N}    %s\n" "$1"; }
bad() { printf "  ${R}[FALLA]${N} %s\n" "$1"; }
avi() { printf "  ${A}[AVISO]${N} %s\n" "$1"; }
sec() { echo ""; echo "--- $1"; }

IN=0; CM=0; SL=0; SC=0; LG=0
ELIM=""

echo "================================================================"
echo " VERIFICACION PRACTICA 10 - v$VERSION"
echo " Carnet: $CARNET        Fecha: $(date '+%Y-%m-%d %H:%M')"
echo " Hash del script: $(sha256sum "$0" 2>/dev/null | cut -c1-16)"
echo "================================================================"

# ---------------------------------------------------------------------------
sec "0. Herramientas y contexto (debe verificarlo el auxiliar)"
FALTAN=""
for t in git jq kubectl curl; do
  command -v "$t" >/dev/null 2>&1 || FALTAN="$FALTAN $t"
done
[ -n "$FALTAN" ] && bad "Herramientas ausentes:$FALTAN" || ok "Todas las herramientas presentes"
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
CODE="$WORK/code"; GITOPS="$WORK/gitops"; P10="$CODE/P10"
[ -d "$P10" ] && ok "Carpeta /P10 presente" || bad "No existe la carpeta /P10"
[ -f "$P10/README.md" ] && ok "README de entrega presente" \
  || { bad "README de entrega AUSENTE"; ELIM="$ELIM readme"; }

# ---------------------------------------------------------------------------
sec "2. Conexion con Prometheus"
if kubectl get svc "$PROM_SVC" -n "$NS_OBS" >/dev/null 2>&1; then
  ok "Servicio de Prometheus encontrado: $PROM_SVC"
  kubectl port-forward -n "$NS_OBS" "svc/$PROM_SVC" 19090:"$PROM_PORT" >/dev/null 2>&1 &
  PF_PID=$!
  sleep 4
else
  bad "No existe el servicio '$PROM_SVC' en el namespace '$NS_OBS'"
  ELIM="$ELIM sin-prometheus"
fi

promql() {
  curl -sG --max-time 8 --data-urlencode "query=$1" \
    "http://localhost:19090/api/v1/query" 2>/dev/null
}
con_datos() { echo "${1:-}" | jq -e '.data.result | length > 0' >/dev/null 2>&1; }

if con_datos "$(promql 'up')"; then
  ok "La API de Prometheus responde"
else
  bad "Prometheus no responde a consultas: los criterios que dependen de metricas saldran en cero"
  ELIM="$ELIM prometheus-sin-datos"
fi

# ---------------------------------------------------------------------------
sec "2.1 Instrumentacion y correlacion (14 pts)"
NSERV=0
for s in $SERVICIOS; do
  if grep -rqil "opentelemetry\|otel" "$CODE" --include="*.json" --include="*.toml" \
       --include="*.txt" --include="*.xml" --include="*.gradle" --include="*.mod" 2>/dev/null \
     && grep -rqi "$s" "$CODE" 2>/dev/null; then
    NSERV=$((NSERV+1))
  fi
done
echo "  Servicios declarados: $(echo "$SERVICIOS" | wc -w)   con rastro de OpenTelemetry: $NSERV"
[ "$NSERV" -ge 3 ] && { ok "Tres o mas servicios instrumentados"; IN=$((IN+4)); } \
                   || bad "Menos de tres servicios con dependencia de OpenTelemetry"
if kubectl get deploy,daemonset,statefulset -A -o name 2>/dev/null | grep -qi "otel\|opentelemetry\|collector"; then
  ok "Collector de OpenTelemetry desplegado"; IN=$((IN+3))
else
  bad "No se encuentra el Collector de OpenTelemetry"
fi
grep -rqiE 'traceparent|propagat|inject\(|extract\(|TraceContext' "$CODE" 2>/dev/null \
  && { ok "Se evidencia propagacion de contexto"; IN=$((IN+2)); } \
  || bad "Sin evidencia de propagacion de contexto entre servicios"
if [ -n "$METRICA_NEGOCIO" ] && con_datos "$(promql "$METRICA_NEGOCIO")"; then
  ok "Metrica de negocio presente en Prometheus: $METRICA_NEGOCIO"; IN=$((IN+5))
else
  bad "La metrica de negocio '$METRICA_NEGOCIO' no devuelve datos"
  avi "Solo hay metricas de infraestructura: revisar criterio 2.1"
fi
echo "  >> 2.1 = $IN / 14"

# ---------------------------------------------------------------------------
sec "2.2 Canary gobernado por metricas (16 pts)"
ATJSON=$(kubectl get analysistemplates -n "$NS" -o json 2>/dev/null)
NAT=$(echo "${ATJSON:-{}}" | jq '[.items[]?] | length' 2>/dev/null || echo 0)
echo "  AnalysisTemplates en $NS: ${NAT:-0}"
if echo "${ATJSON:-{}}" | jq -e '.items[]?.spec.metrics[]?.provider.prometheus' >/dev/null 2>&1; then
  ok "El analisis usa provider prometheus"; CM=$((CM+5))
  if echo "${ATJSON:-{}}" | jq -e '.items[]?.spec.metrics[]? | select(.provider.job)' >/dev/null 2>&1; then
    avi "Tambien quedan metricas de tipo job: confirmar cual gobierna la promocion"
  fi
else
  bad "El analisis NO consulta Prometheus (sigue con Job o no existe)"
  ELIM="$ELIM analisis-sin-prometheus"
fi
mapfile -t CONSULTAS < <(echo "${ATJSON:-{}}" | jq -r '.items[]?.spec.metrics[]?.provider.prometheus.query // empty' 2>/dev/null)
echo "  Consultas declaradas: ${#CONSULTAS[@]}"
for q in "${CONSULTAS[@]}"; do echo "    $(echo "$q" | tr '\n' ' ' | cut -c1-110)"; done
if printf '%s\n' "${CONSULTAS[@]}" | grep -qiE 'canary|rollouts-pod-template-hash|\{\{args'; then
  ok "Las consultas distinguen el trafico del canary"; CM=$((CM+3))
else
  bad "Las consultas no distinguen canary de estable: medirian todo el trafico"
fi
if [ -n "$ROLLOUT" ] && kubectl get rollout "$ROLLOUT" -n "$NS" -o json 2>/dev/null \
   | jq -e '.spec.strategy.canary.steps[]?.analysis' >/dev/null 2>&1; then
  ok "La promocion esta condicionada al analisis"; CM=$((CM+3))
else
  bad "La promocion NO depende del analisis o el Rollout '$ROLLOUT' no existe"
fi
VALIDA=0
for q in "${CONSULTAS[@]}"; do
  LIMPIA=$(echo "$q" | sed 's/{{args\.[^}]*}}/1/g')
  con_datos "$(promql "$LIMPIA")" && { VALIDA=1; break; }
done
[ "$VALIDA" = 1 ] && { ok "Al menos una consulta devuelve datos reales"; CM=$((CM+2)); } \
                  || bad "Ninguna consulta del analisis devuelve datos"
NFAIL=$(kubectl get analysisruns -n "$NS" -o json 2>/dev/null \
        | jq '[.items[]? | select(.status.phase=="Failed" or .status.phase=="Error")] | length' 2>/dev/null || echo 0)
if [ "${NFAIL:-0}" -ge 1 ]; then
  ok "Evidencia de reversion por metricas: $NFAIL AnalysisRun fallido(s)"; CM=$((CM+3))
  kubectl get analysisruns -n "$NS" -o json 2>/dev/null \
    | jq -r '.items[]? | select(.status.phase=="Failed" or .status.phase=="Error")
             | "    run=\(.metadata.name) fase=\(.status.phase)"' 2>/dev/null | head -3
else
  bad "Sin AnalysisRun fallido -> EXIGIR LA DEMOSTRACION EN VIVO"
fi
echo "  >> 2.2 = $CM / 16"

# ---------------------------------------------------------------------------
sec "2.3 SLO y alertas por presupuesto de error (12 pts)"
PRJSON=$(kubectl get prometheusrules -A -o json 2>/dev/null)
NREC=$(echo "${PRJSON:-{}}" | jq '[.items[]?.spec.groups[]?.rules[]? | select(.record)] | length' 2>/dev/null || echo 0)
NALE=$(echo "${PRJSON:-{}}" | jq '[.items[]?.spec.groups[]?.rules[]? | select(.alert)] | length' 2>/dev/null || echo 0)
echo "  Reglas de registro: ${NREC:-0}   reglas de alerta: ${NALE:-0}"
[ "${NREC:-0}" -ge 1 ] && { ok "Existen reglas de registro"; SL=$((SL+3)); } \
                       || bad "Sin reglas de registro (recording rules)"
if [ -n "$REGLA_SLI" ] && con_datos "$(promql "$REGLA_SLI")"; then
  ok "El indicador se calcula y devuelve datos: $REGLA_SLI"; SL=$((SL+2))
else
  bad "La regla '$REGLA_SLI' no devuelve datos"
fi
[ "${NALE:-0}" -ge 1 ] && { ok "Existen reglas de alerta"; SL=$((SL+2)); } \
                       || bad "Sin reglas de alerta"
if echo "${PRJSON:-{}}" | jq -r '.items[]?.spec.groups[]?.rules[]? | select(.alert) | .expr' 2>/dev/null \
   | grep -qiE 'burn|budget|presupuesto|1h.*6h|5m.*1h'; then
  ok "Alertas basadas en consumo del presupuesto"; SL=$((SL+3))
else
  bad "Alertas por umbral instantaneo, no por presupuesto de error"
fi
if echo "${PRJSON:-{}}" | jq -e '.items[]?.spec.groups[]?.rules[]?.annotations
      | with_entries(select(.key|test("runbook";"i"))) | length > 0' >/dev/null 2>&1; then
  ok "Las alertas enlazan a un runbook"; SL=$((SL+2))
else
  bad "Alertas sin anotacion de runbook"
fi
echo "  >> 2.3 = $SL / 12"

# ---------------------------------------------------------------------------
sec "2.4 Recorrido del sintoma a la causa (10 pts)"
PODS_OBS=$(kubectl get pods -n "$NS_OBS" -o name 2>/dev/null)
echo "  Pods en $NS_OBS: $(echo "$PODS_OBS" | grep -c . )"
if echo "$PODS_OBS" | grep -qiE 'loki|elastic|opensearch|fluent'; then
  ok "Almacen de registros desplegado"; SC=$((SC+3))
else
  bad "Sin almacen de registros en $NS_OBS"
fi
DS=$(kubectl get cm -n "$NS_OBS" -o yaml 2>/dev/null)
TIPOS=0
for t in prometheus loki tempo jaeger; do
  echo "${DS:-}" | grep -qi "type: *$t" && TIPOS=$((TIPOS+1))
done
echo "  Origenes de datos detectados en Grafana: $TIPOS"
[ "$TIPOS" -ge 3 ] && { ok "Grafana con metricas, registros y trazas"; SC=$((SC+3)); } \
                   || bad "Grafana no tiene los tres origenes de datos configurados"
if echo "$PODS_OBS" | grep -qiE 'tempo|jaeger' ; then
  ok "Backend de trazas desplegado"; SC=$((SC+4))
  avi "Confirmar en la demostracion que contiene trazas recientes"
else
  bad "Sin backend de trazas"
fi
echo "  >> 2.4 = $SC / 10"

# ---------------------------------------------------------------------------
sec "2.5 Registros estructurados (8 pts)"
POD=$(kubectl get pods -n "$NS" -o name 2>/dev/null | grep -i "$POD_LOGS" | head -1)
if [ -n "$POD" ]; then
  LINEA=$(kubectl logs -n "$NS" "$POD" --tail=20 2>/dev/null | grep '^{' | tail -1)
  if [ -n "$LINEA" ] && echo "$LINEA" | jq -e . >/dev/null 2>&1; then
    ok "Los registros salen en JSON valido"; LG=$((LG+4))
    echo "    $(echo "$LINEA" | cut -c1-120)"
    if echo "$LINEA" | jq -e 'with_entries(select(.key|test("trace";"i"))) | length > 0' >/dev/null 2>&1; then
      ok "El registro incluye identificador de traza"; LG=$((LG+2))
    else
      bad "El registro NO incluye identificador de traza"
    fi
  else
    bad "Los registros no salen en JSON"
  fi
else
  bad "No se encontro un pod que coincida con '$POD_LOGS' en $NS"
fi
if echo "$PODS_OBS" | grep -qiE 'loki|elastic|opensearch'; then
  ok "Los registros se centralizan en un almacen consultable"; LG=$((LG+2))
  avi "Confirmar en la demostracion una consulta real por campo"
else
  bad "Registros no centralizados"
fi
echo "  >> 2.5 = $LG / 8"

# ---------------------------------------------------------------------------
sec "Comprobaciones informativas"
find "$P10" -iname '*dashboard*' -o -iname '*tablero*' 2>/dev/null | grep -q . \
  && ok "Tablero exportado presente en el repositorio" || bad "No se encuentra el tablero exportado"
find "$P10" -iname '*runbook*' 2>/dev/null | grep -q . \
  && ok "Runbooks presentes" || bad "No se encuentran los runbooks"
grep -rqiE 'SLO|SLI|presupuesto de error|error budget' "$P10" 2>/dev/null \
  && ok "El informe menciona SLO y presupuesto" || bad "Sin referencias a SLO en la documentacion"
grep -rqiE 'kind:[[:space:]]*(Application|Kustomization)' "$GITOPS" 2>/dev/null \
  && ok "El stack se despliega por GitOps" || avi "Verificar que el stack no se haya instalado a mano (-5 pts)"

# ---------------------------------------------------------------------------
TOTAL=$((IN + CM + SL + SC + LG))
DUR=$(( $(date +%s) - INICIO ))
echo ""
echo "================================================================"
echo " RESUMEN - carnet $CARNET"
echo "================================================================"
printf "  2.1 Instrumentacion y correlacion ... %2d / 14\n" "$IN"
printf "  2.2 Canary por metricas ............. %2d / 16\n" "$CM"
printf "  2.3 SLO y alertas ................... %2d / 12\n" "$SL"
printf "  2.4 Sintoma a la causa .............. %2d / 10\n" "$SC"
printf "  2.5 Registros estructurados ......... %2d / 8\n"  "$LG"
echo   "  ----------------------------------------------"
printf "  CONOCIMIENTO ........................ %2d / 60\n" "$TOTAL"
echo ""
echo "  Pendiente de evaluacion presencial: 40 pts"
echo "    1.1 SLO (10)   1.2 Tablero (8)"
echo "    1.3 Informe de operacion (12)   1.4 Preguntas teoricas (10)"
echo ""
if [ -n "$ELIM" ]; then
  printf "  ${R}REQUISITOS ELIMINATORIOS INCUMPLIDOS:${N}%s\n" "$ELIM"
  echo "  Revisar la seccion 8.1 del enunciado antes de asignar nota."
else
  printf "  ${V}Requisitos eliminatorios: todos cumplidos${N}\n"
fi
echo ""
echo "  Duracion: ${DUR}s    Reporte: $REPORTE"
echo "================================================================"

[ -f "$CSV" ] || echo "carnet,instrumentacion,canary,slo,causa,registros,total60,eliminatorios" > "$CSV"
echo "$CARNET,$IN,$CM,$SL,$SC,$LG,$TOTAL,\"${ELIM:-ninguno}\"" >> "$CSV"
