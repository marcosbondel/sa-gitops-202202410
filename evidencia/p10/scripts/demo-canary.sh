#!/usr/bin/env bash
# ===========================================================================
# demo-canary.sh — El canary detecta por métricas una versión defectuosa y la
# revierte solo (Práctica 10, §3.2 «Fallo inducido» y criterio 2.2).
#
#     P10/scripts/demo-canary.sh [<número del PR>]
#
# Requisito: el Pull Request que abre el pipeline al publicar la versión
# defectuosa, contra stage:
#
#     git tag p8-v1.3.2-fallo && git push origin p8-v1.3.2-fallo
#
# El fallo (`P10/fallo-inducido/api-gateway.patch`) es distinto al de la P8:
# aquella versión quemaba CPU en cada petición (LATENCIA); esta responde 500 a
# todo cliente que no mande `Accept-Language` (TASA DE ERRORES). Las sondas de
# Kubernetes no lo ven —/health no pasa por esa ruta—, así que el pod
# candidato está `Ready` y recibe tráfico: solo las métricas lo delatan.
#
# Lo que hace, y lo que deja medido en `docs/evidencias/`:
#
#   1. Fusiona el Pull Request: es el «despliegue» del defecto. Nadie toca
#      el clúster; ArgoCD aplica lo que dice Git.
#   2. Espera a que el pod candidato reciba tráfico (peso 10 %): ese es el
#      INICIO DEL FALLO, el primer cliente que puede recibir un 500.
#   3. Sigue cada medición del AnalysisRun y la tasa de errores por versión
#      en Prometheus, hasta que el análisis falla (DETECCIÓN) y Argo Rollouts
#      devuelve todo el tráfico a la versión estable (RECUPERACIÓN).
#   4. Guarda el AnalysisRun fallido, una traza y el registro del error de la
#      versión candidata: la causa, con las tres señales.
#   5. Revierte el Pull Request en GitOps para que Git vuelva a decir la
#      verdad (sin esto, ArgoCD mostraría la aplicación `Degraded` para
#      siempre). Es el único paso humano, y ocurre DESPUÉS de que el sistema
#      ya se protegió solo.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

NS="$NS_STAGE"
REPO_GITOPS="marcosbondel/sa-gitops-202202410"

PR="${1:-$(gh pr list --repo "$REPO_GITOPS" --state open --search "fallo in:title" --json number --jq '.[0].number // empty')}"
[[ -n "$PR" ]] || fallar "no hay un Pull Request abierto de la versión defectuosa (git tag p8-vX.Y.Z-fallo)"

iniciar_registro canary-fallo
abrir_tuneles

marca "inicio" "Pull Request #${PR}: $(gh pr view "$PR" --repo "$REPO_GITOPS" --json title --jq .title)"
marca "inicio" "rollout antes: $(estado_rollout "$NS")"
ESTABLE="$(k -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.stableRS}')"
[[ "$(k -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.phase}')" == "Healthy" ]] \
  || fallar "el Rollout de ${NS} no está Healthy: termine el despliegue anterior antes de la demostración"

# --- 1 · El defecto entra por Git ----------------------------------------------
gh pr merge "$PR" --repo "$REPO_GITOPS" --squash >/dev/null
T_FUSION=$(ahora_epoch)
marca "git" "Pull Request #${PR} fusionado en main: la versión defectuosa queda declarada en Git"
refrescar_argocd sa-p9-raiz sa-p8-plataforma-stage

# --- 2 · El defecto recibe tráfico ---------------------------------------------
NUEVO=""
until [[ -n "$NUEVO" && "$NUEVO" != "$ESTABLE" ]]; do
  sleep 3
  NUEVO="$(k -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.currentPodHash}' 2>/dev/null || true)"
done
marca "rollout" "ReplicaSet candidato ${NUEVO} creado (estable: ${ESTABLE})"
until [[ "$(k -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.canary.weights.canary.weight}' 2>/dev/null)" -gt 0 ]]; do
  sleep 2
done
T_INICIO_FALLO=$(ahora_epoch)
marca "fallo" "INICIO DEL FALLO: la versión candidata recibe tráfico real — $(estado_rollout "$NS")"

# --- 3 · Medición, detección y reversión ---------------------------------------
ERRORES_CANARY="(sum(rate(http_server_request_duration_seconds_count{namespace=\"${NS}\",service=\"api-gateway\",rollouts_pod_template_hash=\"${NUEVO}\",http_response_status_code=~\"5..\"}[1m])) or on() vector(0)) / sum(rate(http_server_request_duration_seconds_count{namespace=\"${NS}\",service=\"api-gateway\",rollouts_pod_template_hash=\"${NUEVO}\"}[1m]))"
ERRORES_ESTABLE="${ERRORES_CANARY//${NUEVO}/${ESTABLE}}"
# Fracción → porcentaje con un decimal; sin datos (o NaN) cuenta como 0.
porcentaje() { local v; v="$(promql "$1")"; awk -v v="${v:-0}" 'BEGIN { if (v == "NaN") v = 0; printf "%.1f", v * 100 }'; }
VISTAS=""
T_DETECCION=""
T_RECUPERACION=""
while :; do
  CORRIDA="$(k -n "$NS" get analysisrun -l "rollouts-pod-template-hash=${NUEVO}" -o json 2>/dev/null \
            | jq -r '[.items[]] | sort_by(.metadata.creationTimestamp) | last // empty')"
  if [[ -n "$CORRIDA" ]]; then
    NOMBRE_RUN="$(jq -r .metadata.name <<<"$CORRIDA")"
    # Cada medición nueva, una vez.
    while read -r linea; do
      [[ -z "$linea" ]] && continue
      if [[ "$VISTAS" != *"|${linea}|"* ]]; then
        VISTAS="${VISTAS}|${linea}|"
        marca "analisis" "${NOMBRE_RUN} · ${linea}"
      fi
    done < <(jq -r '.status.metricResults[]? | .name as $m | .measurements[]? | select(.finishedAt) |
                    "\($m): \(.phase) valor=\(.value) (\(.finishedAt))"' <<<"$CORRIDA")
    FASE="$(jq -r '.status.phase // ""' <<<"$CORRIDA")"
    if [[ -z "$T_DETECCION" && ( "$FASE" == "Failed" || "$FASE" == "Error" ) ]]; then
      T_DETECCION=$(ahora_epoch)
      marca "deteccion" "DETECCIÓN: AnalysisRun ${NOMBRE_RUN} en ${FASE} — $(jq -r '.status.message // ""' <<<"$CORRIDA")"
    fi
  fi
  marca "metricas" "5xx candidata $(porcentaje "$ERRORES_CANARY") % · estable $(porcentaje "$ERRORES_ESTABLE") % · $(estado_rollout "$NS")"
  ABORTADO="$(k -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.abort}')"
  PESO="$(k -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.canary.weights.canary.weight}')"
  if [[ -n "$T_DETECCION" && "$ABORTADO" == "true" && "${PESO:-0}" == "0" ]]; then
    T_RECUPERACION=$(ahora_epoch)
    marca "recuperacion" "RECUPERACIÓN: Argo Rollouts abortó; 100 % del tráfico en la versión estable ${ESTABLE}, sin intervención"
    break
  fi
  (( $(ahora_epoch) - T_INICIO_FALLO < 900 )) || fallar "15 minutos sin detección: revisar el AnalysisRun a mano"
  sleep 10
done

# --- 4 · La evidencia: AnalysisRun, traza y registro ---------------------------
DIR_EV="${REGISTRO%.log}"
mkdir -p "$DIR_EV"
k -n "$NS" get analysisrun "$NOMBRE_RUN" -o yaml >"${DIR_EV}/analysisrun-${NOMBRE_RUN}.yaml"
k -n "$NS" get rollout "$ROLLOUT" -o yaml >"${DIR_EV}/rollout-despues.yaml"
k -n "$NS" get analysisrun -o wide >"${DIR_EV}/analysisruns.txt"
marca "evidencia" "AnalysisRun guardado: $(basename "${DIR_EV}")/analysisrun-${NOMBRE_RUN}.yaml"

DESDE=$(( T_INICIO_FALLO - 60 )); HASTA=$(( $(ahora_epoch) + 5 ))
LINEA="$(loki_consulta "{k8s_namespace_name=\"${NS}\", service_name=\"api-gateway\"} | json | level=\"error\" | message=\"error no controlado\"" "$DESDE" "$HASTA" | head -1)"
if [[ -n "$LINEA" ]]; then
  TRAZA="$(jq -r .trace_id <<<"$LINEA")"
  marca "causa" "registro del error (Loki) — $(jq -c '{timestamp, service, message, trace_id, "error.type", "error.message"}' <<<"$LINEA")"
  printf '%s\n' "$LINEA" | jq . >"${DIR_EV}/registro-error.json"
  sleep 5
  tempo_traza "$TRAZA" >"${DIR_EV}/traza-${TRAZA}.json" || true
  jq -r '.trace.resourceSpans[] | (.resource.attributes[] | select(.key=="service.name") | .value.stringValue) as $s
         | .scopeSpans[].spans[] | select(.status.code=="STATUS_CODE_ERROR")
         | "\($s) · \(.name) · \(.events[0].attributes[]? | select(.key=="exception.message") | .value.stringValue)"' \
      "${DIR_EV}/traza-${TRAZA}.json" 2>/dev/null | head -3 | while read -r s; do marca "causa" "span en error (Tempo): $s"; done
fi

# --- 5 · Git vuelve a decir la verdad ------------------------------------------
# En un worktree temporal sobre origin/main, para no tocar la rama en la que
# esté trabajando el operador en su copia del repositorio.
WT="$(mktemp -d)/gitops"
gitops fetch -q origin main
gitops worktree add -q --detach "$WT" origin/main
COMMIT="$(git -C "$WT" log -1 --format=%H --grep "(#${PR})")"
[[ -n "$COMMIT" ]] || fallar "no encuentro en main el commit del Pull Request #${PR}"
git -C "$WT" revert --no-edit "$COMMIT" >/dev/null
git -C "$WT" push -q origin HEAD:main
gitops worktree remove --force "$WT"
marca "git" "revertido ${COMMIT:0:7} en GitOps: stage vuelve a declarar la versión estable"
refrescar_argocd sa-p9-raiz sa-p8-plataforma-stage
until [[ "$(k -n "$NS" get rollout "$ROLLOUT" -o jsonpath='{.status.phase}')" == "Healthy" ]]; do sleep 5; done
marca "fin" "rollout después: $(estado_rollout "$NS")"

# --- Resumen -------------------------------------------------------------------
mmss() { printf '%d min %02d s' $(( $1 / 60 )) $(( $1 % 60 )); }
{
  echo
  echo "RESUMEN"
  echo "  versión defectuosa      ${NUEVO} (estable ${ESTABLE})"
  echo "  AnalysisRun fallido     ${NOMBRE_RUN}"
  echo "  fusión → tráfico        $(mmss $(( T_INICIO_FALLO - T_FUSION )))"
  echo "  tiempo de detección     $(mmss $(( T_DETECCION - T_INICIO_FALLO )))   (primer cliente expuesto → AnalysisRun Failed)"
  echo "  tiempo de recuperación  $(mmss $(( T_RECUPERACION - T_INICIO_FALLO )))   (primer cliente expuesto → 100 % en la estable)"
  echo "  intervención humana     ninguna hasta la recuperación"
} | tee -a "$REGISTRO"
