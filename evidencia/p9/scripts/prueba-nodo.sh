#!/usr/bin/env bash
# ===========================================================================
# prueba-nodo.sh — Pérdida de un nodo con el servicio respondiendo (§3.2, 2.5).
#
#     P9/scripts/prueba-nodo.sh                 # el nodo «típico» (ver abajo)
#     P9/scripts/prueba-nodo.sh --nodo <nombre> # uno concreto
#     P9/scripts/prueba-nodo.sh --peor-caso     # el nodo de PostgreSQL
#
# Drena un nodo con `kubectl drain` —el mismo mecanismo que usa GKE para
# actualizar o reparar nodos— mientras dos sondas golpean la URL pública:
#
#   /health/ready  cada 1 s  balanceador → ingress-nginx → gateway
#   /health        cada 2 s  lo anterior + los 4 servicios y sus bases
#
# ## Qué nodo
#
# Por defecto, uno que aloje a la vez una réplica del gateway de producción y
# una del controlador de ingress, y que NO aloje a PostgreSQL: es el caso
# que el diseño dice cubrir —componentes replicados con PDB y anti-afinidad—.
#
# `--peor-caso` drena el nodo de PostgreSQL, que tiene UNA réplica y es un
# punto único de fallo DECLARADO (informe de DR). Se ofrece para medir
# cuánto cuesta, no para esconderlo.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

NODO=""; MODO="tipico"
case "${1:-}" in
  --nodo) NODO="${2:?falta el nombre del nodo}"; MODO="elegido" ;;
  --peor-caso) MODO="peor-caso" ;;
esac

iniciar_registro "prueba-nodo-${MODO}"
DATOS="${REGISTRO%.log}"; mkdir -p "$DATOS"
credenciales_cluster || fallar "no hay clúster"

topologia() {
  marca "topologia" "$1"
  {
    printf '        %-46s %s\n' "NODO" "PODS RELEVANTES"
    for n in $(k get nodes -o name | cut -d/ -f2); do
      pods=$(k get pods -A --field-selector "spec.nodeName=${n},status.phase=Running" --no-headers \
        -o custom-columns='NS:.metadata.namespace,N:.metadata.name' 2>/dev/null \
        | awk '$1=="sa-p8-prod" || $1=="ingress-nginx" || ($1=="kyverno" && $2 ~ /admission/) {if ($2 ~ /-[0-9]+$/) sub(/-[0-9]+$/, "", $2); else sub(/-[a-z0-9]+-[a-z0-9]+$/, "", $2); print $2}' \
        | sort | uniq -c | awk '{printf "%s×%s ", $1, $2}')
      sched=$(k get node "$n" -o jsonpath='{.spec.unschedulable}')
      printf '        %-46s %s%s\n' "$n" "${sched:+[CORDONADO] }" "$pods"
    done
  } | tee -a "$REGISTRO"
}

nodo_de() {  # nodo_de <namespace> <selector>
  k -n "$1" get pods -l "$2" -o jsonpath='{range .items[*]}{.spec.nodeName}{"\n"}{end}' | sort -u
}

topologia "distribución ANTES del drenaje"
ejecutar "pdb" "PodDisruptionBudget antes del drenaje" -- k get pdb -A

if [[ -z "$NODO" ]]; then
  PG=$(nodo_de "$NS_PROD" "app.kubernetes.io/name=postgresql")
  if [[ "$MODO" == "peor-caso" ]]; then
    NODO="$PG"
  else
    gw=$(nodo_de "$NS_PROD" "app.kubernetes.io/name=api-gateway")
    ing=$(nodo_de ingress-nginx "app.kubernetes.io/component=controller")
    NODO=$(comm -12 <(echo "$gw") <(echo "$ing") | grep -vx "${PG:-ninguno}" | head -n 1 || true)
    [[ -n "$NODO" ]] || NODO=$(echo "$gw" | grep -vx "${PG:-ninguno}" | head -n 1)
  fi
fi
[[ -n "$NODO" ]] || fallar "no se pudo elegir un nodo"
marca "prueba" "nodo a drenar: ${NODO} (modo ${MODO})"

sonda_iniciar "$DATOS/sonda-ready.txt" /health/ready 1; PID_A=$SONDA_PID
sonda_iniciar "$DATOS/sonda-health.txt" /health 2; PID_B=$SONDA_PID
parar_sondas() {
  SONDA_PID=$PID_A; sonda_parar "$DATOS/sonda-ready.txt"
  SONDA_PID=$PID_B; sonda_parar "$DATOS/sonda-health.txt"
}
trap 'parar_sondas; k uncordon "$NODO" >/dev/null 2>&1 || true' EXIT
marca "prueba" "sondas en marcha; 30 s de línea base"
sleep 30

# --- El drenaje ------------------------------------------------------------------
# Sin --force y sin --disable-eviction: el drenaje respeta los PDB. Si un PDB
# se lo impide, `kubectl drain` reintenta y lo dice en su salida («Cannot
# evict pod as it would violate the pod's disruption budget»): esa línea, si
# aparece, es la evidencia de que el PDB está haciendo su trabajo.
T_DRENAJE="$(ahora_iso)"
marca "drenaje" "═══ T_drenaje = ${T_DRENAJE}: kubectl drain ${NODO} ═══"
ejecutar "drenaje" "kubectl drain" -- \
  k drain "$NODO" --ignore-daemonsets --delete-emptydir-data --timeout=15m
marca "drenaje" "nodo vacío; esperando a que los pods desalojados estén Ready en los otros nodos"
k -n "$NS_PROD" wait --for=condition=Ready pod --all --timeout=600s \
  --field-selector=status.phase=Running >/dev/null 2>&1 || true
sleep 60
topologia "distribución con ${NODO} drenado"
ejecutar "pdb" "PodDisruptionBudget con el nodo drenado" -- k get pdb -A

marca "drenaje" "uncordon ${NODO}"
k uncordon "$NODO" >/dev/null
sleep 30
parar_sondas; trap - EXIT

{
  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo " DISPONIBILIDAD DURANTE LA PÉRDIDA DEL NODO ${NODO}"
  echo "════════════════════════════════════════════════════════════════════"
  echo "/health/ready (cada 1 s) — balanceador, ingress y gateway:"
  sonda_resumen "$DATOS/sonda-ready.txt" | sed 's/^/  /'
  echo "/health (cada 2 s) — de punta a punta, con los 4 servicios:"
  sonda_resumen "$DATOS/sonda-health.txt" | sed 's/^/  /'
  echo
  echo "Peticiones fallidas (si las hubo), con su hora:"
  awk '$2 != "200" {print "  ready   " $0}' "$DATOS/sonda-ready.txt"
  awk '$2 != "200" {print "  health  " $0}' "$DATOS/sonda-health.txt"
} | tee -a "$REGISTRO"
marca "fin" "prueba de pérdida de nodo terminada → ${REGISTRO#"${RAIZ}/"}"
