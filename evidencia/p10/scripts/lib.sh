#!/usr/bin/env bash
# Se carga con `source`: las variables se usan en los scripts que la cargan.
# shellcheck disable=SC2034
# ===========================================================================
# lib.sh — Funciones de los scripts de la Práctica 10.
#
# Se carga DESPUÉS de `config.sh`. Toma de la P9 las funciones de clúster
# (`k`, `estado_apps`, …) y define aquí las propias: el registro con marcas
# de tiempo de la P10, los túneles al stack de observabilidad y las consultas
# a Prometheus, Alertmanager, Tempo y Loki.
#
# ## Por qué todo lleva hora UTC
#
# El informe de operación pide tiempos MEDIDOS: detección, recorrido hasta la
# causa, recuperación. Salen de restar marcas de este registro, y se cruzan
# con las marcas de Prometheus (`startsAt` de una alerta), de Kubernetes y
# de Git, que están todas en UTC.
# ===========================================================================

# shellcheck source=../../P9/scripts/lib.sh
source "${P10_DIR}/../P9/scripts/lib.sh"

# El encabezado del registro es el de la P10, no el de la P9.
iniciar_registro() {
  if [[ -z "$REGISTRO" ]]; then
    mkdir -p "$EVIDENCIAS"
    REGISTRO="${EVIDENCIAS}/${1}-$(date -u +%Y%m%dT%H%M%SZ).log"
    T_INICIO="$(ahora_epoch)"
    export REGISTRO T_INICIO
    {
      echo "# ${1} — Práctica 10 (202202410)"
      echo "# inicio:   $(ahora_iso)"
      echo "# máquina:  $(uname -sm)"
      echo "# proyecto: ${PROJECT_ID} · clúster ${CLUSTER}"
      echo "# comando:  $0 $*"
      echo "#"
      echo "# Formato:  <UTC>  +<min:seg desde el inicio>  [etapa]  mensaje"
      echo
    } >"$REGISTRO"
  fi
}

# Escribe un bloque de texto en el registro, indentado (sin marca de tiempo).
anexar() { sed 's/^/        /' | tee -a "${REGISTRO:-/dev/null}"; }

# --- Túneles -----------------------------------------------------------------
TUNELES=()

# abrir_tuneles: Prometheus, Alertmanager, Tempo, Loki y Grafana en localhost.
# Se cierran solos al salir del script.
abrir_tuneles() {
  local pares=(
    "prometheus-operated:${PUERTO_PROMETHEUS}:9090"
    "alertmanager-operated:${PUERTO_ALERTMANAGER}:9093"
    "tempo:${PUERTO_TEMPO}:3200"
    "loki:${PUERTO_LOKI}:3100"
    "kube-prometheus-stack-grafana:${PUERTO_GRAFANA}:80"
  )
  local par svc puerto_local remoto
  for par in "${pares[@]}"; do
    IFS=: read -r svc puerto_local remoto <<<"$par"
    k -n "$NS_OBS" port-forward "svc/${svc}" "${puerto_local}:${remoto}" >/dev/null 2>&1 &
    TUNELES+=("$!")
  done
  trap cerrar_tuneles EXIT
  local intento
  for intento in $(seq 1 20); do
    curl -sf -o /dev/null "http://localhost:${PUERTO_PROMETHEUS}/-/ready" \
      && curl -sf -o /dev/null "http://localhost:${PUERTO_LOKI}/ready" \
      && curl -sf -o /dev/null "http://localhost:${PUERTO_TEMPO}/ready" \
      && return 0
    sleep 1
  done
  echo "ERROR: los túneles al stack de observabilidad no respondieron" >&2
  return 1
}

cerrar_tuneles() {
  local pid
  # `|| true`: un túnel que no llegó a abrirse (el puerto ya lo tenía otro
  # script) ya terminó, y `kill` sobre él devuelve 1. Con `set -e`, ese 1
  # dentro del trap de salida cambiaría el código de salida del script.
  for pid in "${TUNELES[@]:-}"; do
    [[ -n "$pid" ]] && { kill "$pid" 2>/dev/null || true; }
  done
  return 0
}

# --- Consultas -----------------------------------------------------------------

# promql <expresión> → el primer valor del resultado, o vacío.
promql() {
  curl -sG --max-time 10 "http://localhost:${PUERTO_PROMETHEUS}/api/v1/query" \
    --data-urlencode "query=$1" \
    | jq -r '.data.result[0].value[1] // empty' 2>/dev/null
}

# promql_tabla <expresión> → «etiquetas = valor», una línea por serie.
promql_tabla() {
  curl -sG --max-time 10 "http://localhost:${PUERTO_PROMETHEUS}/api/v1/query" \
    --data-urlencode "query=$1" \
    | jq -r '.data.result[] | "\(.metric | del(.__name__) | to_entries | map("\(.key)=\(.value)") | join(", ")) = \(.value[1])"' 2>/dev/null
}

# alertas_activas → JSON de Alertmanager con las alertas que están sonando.
alertas_activas() {
  curl -s --max-time 10 "http://localhost:${PUERTO_ALERTMANAGER}/api/v2/alerts?active=true&silenced=false&inhibited=false"
}

# tempo_buscar <TraceQL> <desde_epoch> <hasta_epoch> → IDs de traza, uno por línea.
tempo_buscar() {
  curl -sG --max-time 15 "http://localhost:${PUERTO_TEMPO}/api/search" \
    --data-urlencode "q=$1" --data-urlencode "start=$2" --data-urlencode "end=$3" \
    --data-urlencode "limit=20" \
    | jq -r '.traces[]?.traceID'
}

tempo_traza() { curl -s --max-time 15 "http://localhost:${PUERTO_TEMPO}/api/v2/traces/$1"; }

# loki_consulta <LogQL> <desde_epoch> <hasta_epoch> [forward|backward]
#   → hasta 50 líneas; por defecto las MÁS RECIENTES. Para «la primera vez que
#   pasó algo» hay que pedir `forward`: con `backward` y un orden posterior se
#   obtendría la más antigua de las 50 últimas, no la primera.
loki_consulta() {
  curl -sG --max-time 15 "http://localhost:${PUERTO_LOKI}/loki/api/v1/query_range" \
    --data-urlencode "query=$1" --data-urlencode "start=${2}000000000" \
    --data-urlencode "end=${3}000000000" --data-urlencode "limit=50" --data-urlencode "direction=${4:-backward}" \
    | jq -r '.data.result[]?.values[]?[1]'
}

contrasena_grafana() {
  k -n "$NS_OBS" get secret "$SECRETO_GRAFANA" -o jsonpath='{.data.admin-password}' | base64 -d
}

# --- Rollout -------------------------------------------------------------------
# estado_rollout <namespace> → «fase · paso · peso del canary · hash estable · hash nuevo»
estado_rollout() {
  k -n "$1" get rollout "$ROLLOUT" -o json | jq -r '
    "\(.status.phase) · paso \(.status.currentStepIndex // "-")/\(.spec.strategy.canary.steps | length) · peso canary \(.status.canary.weights.canary.weight // 0) % · estable \(.status.stableRS) · nuevo \(.status.currentPodHash)\(if .status.abort then " · ABORTADO" else "" end)"'
}

# --- GitOps --------------------------------------------------------------------
gitops() { git -C "$GITOPS_DIR" "$@"; }

refrescar_argocd() {
  local app
  for app in "$@"; do
    k -n argocd annotate application "$app" argocd.argoproj.io/refresh=normal --overwrite >/dev/null
  done
}
