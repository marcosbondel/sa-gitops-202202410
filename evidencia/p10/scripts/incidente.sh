#!/usr/bin/env bash
# ===========================================================================
# incidente.sh — Un incidente de producción que el canary NO puede ver, de
# punta a punta y con el cronómetro corriendo (Práctica 10: alerta por
# consumo del presupuesto, recorrido del síntoma a la causa e informe).
#
#     P10/scripts/incidente.sh
#
# ## El fallo
#
# Un cambio de configuración en producción, por GitOps, como cualquier otro:
# order-service pasa a buscar el catálogo en el puerto 4001 en lugar del 4000.
# Es el error más común y el más difícil de ver desde dentro:
#
#   · no pasa por el canary: order-service es un Deployment y el cambio es de
#     configuración, no una versión nueva del gateway;
#   · Kubernetes lo da por bueno: los pods arrancan, la readiness consulta
#     PostgreSQL —que está bien— y quedan `Ready`; ArgoCD queda `Healthy`;
#   · para el cliente, toda compra tarda 5 s y termina en un error 503.
#
# Lo que el sistema reporta sobre sí mismo y lo que el cliente experimenta se
# separan por completo. Solo el SLO, medido en el gateway, lo ve.
#
# ## Lo que se mide
#
#   inicio del fallo   primer registro de error del checkout tras el cambio
#   detección          la alerta CheckoutPresupuestoQuemaRapida suena
#   recorrido          `recorrido.sh`: alerta → métricas → traza → registro
#   recuperación       revertir el commit en GitOps → las compras vuelven a
#                      salir sin error (tasa de 5xx del checkout en cero)
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

NS="$NS_PROD"
iniciar_registro incidente-checkout
abrir_tuneles

CHECKOUT_5XX="sum(rate(http_server_request_duration_seconds_count{namespace=\"${NS}\", service=\"api-gateway\", http_route=\"/api/orders\", http_request_method=\"POST\", http_response_status_code=~\"5..\"}[1m])) or on() vector(0)"

marca "inicio" "estado antes: $(k -n "$NS" get deploy sa-platform-order-service -o jsonpath='{.status.readyReplicas}/{.spec.replicas} réplicas listas') de order-service · presupuesto del checkout restante $(promql 'slo:checkout_disponibilidad:presupuesto_restante:ratio30d' | awk '{printf "%.1f %%", $1*100}')"
[[ -z "$(alertas_activas | jq -r --arg a "$ALERTA_CHECKOUT" '.[] | select(.labels.alertname == $a) | .labels.alertname')" ]] \
  || fallar "la alerta ${ALERTA_CHECKOUT} ya está sonando; esperar a que se resuelva"

# --- El cambio defectuoso, por GitOps -------------------------------------------
WT="$(mktemp -d)/gitops"
gitops fetch -q origin main
gitops worktree add -q --detach "$WT" origin/main
/usr/bin/env python3 - "$WT/envs/prod/values.yaml" <<'PY'
import sys
ruta = sys.argv[1]
texto = open(ruta).read()
ancla = "\norder-service:\n"
assert ancla in texto, "no encuentro el bloque order-service"
texto = texto.replace(ancla, ancla + (
    "  # Nuevo puerto del catálogo.\n"
    "  serviceRefs:\n"
    "    CATALOG_SERVICE_URL: { name: catalog-service, port: 4001 }\n"
), 1)
open(ruta, "w").write(texto)
PY
git -C "$WT" commit -qam "prod: order-service apunta al nuevo puerto del catálogo"
git -C "$WT" push -q origin HEAD:main
COMMIT_FALLO="$(git -C "$WT" rev-parse HEAD)"
T_CAMBIO=$(ahora_epoch)
marca "git" "commit ${COMMIT_FALLO:0:7} en GitOps (main): «prod: order-service apunta al nuevo puerto del catálogo» — FALLO INDUCIDO"
git -C "$WT" show --stat --format= HEAD | anexar
refrescar_argocd sa-p9-raiz sa-p8-plataforma-prod

# --- Inicio del fallo ----------------------------------------------------------
until [[ "$(promql "$CHECKOUT_5XX" | awk '{print ($1 > 0)}')" == "1" ]]; do sleep 5; done
marca "fallo" "el checkout de producción empieza a responder 5xx (Prometheus)"
marca "fallo" "Kubernetes mientras tanto: order-service $(k -n "$NS" get deploy sa-platform-order-service -o jsonpath='{.status.readyReplicas}/{.spec.replicas}') Ready · ArgoCD $(k -n argocd get application sa-p8-plataforma-prod -o jsonpath='{.status.sync.status}/{.status.health.status}')"

# --- Detección -------------------------------------------------------------------
until [[ -n "$(alertas_activas | jq -r --arg a "$ALERTA_CHECKOUT" '.[] | select(.labels.alertname == $a) | .startsAt')" ]]; do
  marca "espera" "sin alerta todavía · tasa de quema 5 min $(promql 'slo:checkout_disponibilidad:burnrate5m' | awk '{printf "%.1f", $1}') · 1 h $(promql 'slo:checkout_disponibilidad:burnrate1h' | awk '{printf "%.1f", $1}') (umbral 14,4)"
  sleep 20
done
T_ALERTA=$(ahora_epoch)
marca "deteccion" "ALERTA recibida en Alertmanager: ${ALERTA_CHECKOUT}"

# --- Recorrido del síntoma a la causa --------------------------------------------
"$DIR/recorrido.sh" "$ALERTA_CHECKOUT"
T_CAUSA=$(ahora_epoch)

# --- Recuperación: revertir en Git ---------------------------------------------
gitops fetch -q origin main
git -C "$WT" checkout -q --detach origin/main
git -C "$WT" revert --no-edit "$COMMIT_FALLO" >/dev/null
git -C "$WT" push -q origin HEAD:main
T_REVERSION=$(ahora_epoch)
marca "remedio" "revertido ${COMMIT_FALLO:0:7} en GitOps; ArgoCD vuelve a la configuración anterior"
gitops worktree remove --force "$WT"
refrescar_argocd sa-p9-raiz sa-p8-plataforma-prod
k -n "$NS" rollout status deploy/sa-platform-order-service --timeout=5m | anexar
until [[ "$(promql "$CHECKOUT_5XX" | awk '{print ($1 == 0)}')" == "1" ]]; do sleep 5; done
T_RECUPERADO=$(ahora_epoch)
marca "recuperacion" "las compras vuelven a salir sin error (5xx del checkout en el último minuto: 0)"

# --- Tiempos exactos desde los registros --------------------------------------------
PRIMER_ERROR="$(loki_consulta "{k8s_namespace_name=\"${NS}\", service_name=\"order-service\"} | json | level=\"error\"" "$T_CAMBIO" "$T_ALERTA" forward \
               | jq -r '.timestamp' | sort | head -1)"
a_epoch() { date -u -j -f '%Y-%m-%dT%H:%M:%S' "${1%%.*}" +%s 2>/dev/null || date -u -d "$1" +%s; }
T_PRIMER_ERROR=$(a_epoch "$PRIMER_ERROR")
marca "tiempos" "primer registro de error de order-service tras el cambio: ${PRIMER_ERROR}"
# La recuperación, desde el punto de vista del cliente: la primera compra que
# el gateway vuelve a responder con 201 después de revertir.
PRIMERA_COMPRA="$(loki_consulta "{k8s_namespace_name=\"${NS}\", service_name=\"api-gateway\"} | json | http_route=\"/api/orders\" | http_request_method=\"POST\" | http_response_status_code=\"201\"" "$T_REVERSION" "$(( $(ahora_epoch) + 5 ))" forward \
                  | jq -r '.timestamp' | sort | head -1)"
if [[ -n "$PRIMERA_COMPRA" ]]; then
  T_RECUPERADO=$(a_epoch "$PRIMERA_COMPRA")
  marca "tiempos" "primera compra exitosa tras revertir: ${PRIMERA_COMPRA}"
fi
ALERTA_DESDE="$(alertas_activas | jq -r --arg a "$ALERTA_CHECKOUT" '.[] | select(.labels.alertname == $a) | .startsAt' | head -1)"

mmss() { printf '%d min %02d s' $(( $1 / 60 )) $(( $1 % 60 )); }
{
  echo
  echo "RESUMEN"
  echo "  cambio en Git                 $(date -u -r "$T_CAMBIO" +%H:%M:%SZ)"
  echo "  inicio del fallo              ${PRIMER_ERROR}   (primer registro de error)"
  echo "  alerta (Alertmanager)         $(date -u -r "$T_ALERTA" +%H:%M:%SZ)   startsAt ${ALERTA_DESDE:-resuelta}"
  echo "  tiempo de detección           $(mmss $(( T_ALERTA - T_PRIMER_ERROR )))"
  echo "  recorrido alerta → causa      $(cat "${EVIDENCIAS}"/recorrido-*.segundos 2>/dev/null | tail -1) s   (recorrido.sh)"
  echo "  reversión en Git              $(date -u -r "$T_REVERSION" +%H:%M:%SZ)   (decisión humana tras el recorrido)"
  echo "  recuperado                    $(date -u -r "$T_RECUPERADO" +%H:%M:%SZ)   (primera compra con 201 tras revertir)"
  echo "  tiempo de recuperación        $(mmss $(( T_RECUPERADO - T_PRIMER_ERROR )))   (inicio del fallo → compras sin error)"
  echo "  de la causa a la recuperación $(mmss $(( T_RECUPERADO - T_CAUSA )))"
  echo "  presupuesto del checkout que queda: $(promql 'slo:checkout_disponibilidad:presupuesto_restante:ratio30d' | awk '{printf "%.1f %%", $1*100}')"
} | tee -a "$REGISTRO"
