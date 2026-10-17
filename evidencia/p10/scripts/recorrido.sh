#!/usr/bin/env bash
# ===========================================================================
# recorrido.sh — De la alerta al registro del error, cronometrado
# (Práctica 10, criterio 2.4).
#
#     P10/scripts/recorrido.sh [<alerta>]        # por defecto CheckoutPresupuestoQuemaRapida
#
# Es el procedimiento del runbook
# (`docs/runbooks/checkout-quema-rapida.md`, «Los primeros tres minutos»),
# paso por paso, contra las APIs de los mismos componentes que Grafana
# consulta. Cada paso usa UNA señal y deja su hora:
#
#   0  alerta     Alertmanager      ¿qué suena, desde cuándo, qué runbook?
#   1  métricas   Prometheus        ¿qué servicio falla y con qué motivo?
#   2  trazas     Tempo (TraceQL)   ¿en qué paso de la petición se rompe?
#   3  registros  Loki              ¿por qué? — el mensaje, la URL, el error
#
# El enlace entre 2 y 3 es el `trace_id`: el registro se busca por el
# identificador de la traza, no por la hora ni por el nombre del pod. Ningún
# paso revisa los registros servicio por servicio.
#
# En el video el mismo recorrido se hace a mano en Grafana; este script es la
# versión reproducible, y su tiempo es el que se informa como medido.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

ALERTA="${1:-$ALERTA_CHECKOUT}"
NS="$NS_PROD"

iniciar_registro recorrido
[[ ${#TUNELES[@]} -gt 0 ]] || abrir_tuneles

T0=$(ahora_epoch)
marca "recorrido" "▶ inicio del recorrido desde la alerta ${ALERTA}"

# --- 0 · La alerta -------------------------------------------------------------
A="$(alertas_activas | jq -c --arg a "$ALERTA" '[.[] | select(.labels.alertname == $a)] | first // empty')"
[[ -n "$A" ]] || fallar "la alerta ${ALERTA} no está sonando en Alertmanager"
DESDE_ALERTA="$(jq -r .startsAt <<<"$A")"
marca "0·alerta" "$(jq -r '"\(.labels.alertname) · severidad \(.labels.severity) · SLO \(.labels.slo) · sonando desde \(.startsAt)"' <<<"$A")"
marca "0·alerta" "resumen: $(jq -r .annotations.summary <<<"$A")"
marca "0·alerta" "runbook: $(jq -r .annotations.runbook_url <<<"$A")"

# --- 1 · Métricas: ¿dónde? ----------------------------------------------------
marca "1·metricas" "5xx por servicio (últimos 5 min, ${NS}):"
promql_tabla "sum by (service) (rate(http_server_request_duration_seconds_count{namespace=\"${NS}\", http_response_status_code=~\"5..\"}[5m]))" | anexar
marca "1·metricas" "compras perdidas por motivo (por minuto):"
promql_tabla "sum by (motivo) (rate(pedidos_rechazados_total{namespace=\"${NS}\"}[5m])) * 60" | anexar
SERVICIO="$(curl -sG "http://localhost:${PUERTO_PROMETHEUS}/api/v1/query" \
  --data-urlencode "query=topk(1, sum by (service) (rate(http_server_request_duration_seconds_count{namespace=\"${NS}\", service!=\"api-gateway\", http_response_status_code=~\"5..\"}[5m])))" \
  | jq -r '.data.result[0].metric.service // "api-gateway"')"
T1=$(ahora_epoch)
marca "1·metricas" "✓ el error nace en ${SERVICIO} (el gateway solo lo reenvía) · +$(( T1 - T0 )) s"

# --- 2 · Trazas: ¿en qué paso? -------------------------------------------------
AHORA=$(ahora_epoch)
TRAZA="$(tempo_buscar "{ resource.service.name = \"${SERVICIO}\" && resource.k8s.namespace.name = \"${NS}\" && status = error }" $(( AHORA - 900 )) "$AHORA" | head -1)"
[[ -n "$TRAZA" ]] || fallar "Tempo no devolvió trazas con error de ${SERVICIO}"
tempo_traza "$TRAZA" >"/tmp/recorrido-traza-$$.json"
marca "2·trazas" "traza con error: ${TRAZA} — cascada:"
jq -r '[.trace.resourceSpans[] | (.resource.attributes[] | select(.key=="service.name") | .value.stringValue) as $s
        | .scopeSpans[].spans[] | {s: $s, n: .name, i: (.startTimeUnixNano|tonumber),
            ms: (((.endTimeUnixNano|tonumber) - (.startTimeUnixNano|tonumber)) / 1e6),
            e: (.status.code // "" | test("ERROR")),
            url: ([.attributes[]? | select(.key=="url.full" or .key=="http.url") | .value.stringValue] | first // "")}]
       | sort_by(.i) | .[] | select(.n | test("^middleware") | not)
       | "\(if .e then "✗" else " " end) \(.s) · \(.n) · \(.ms | floor) ms \(.url)"' "/tmp/recorrido-traza-$$.json" | head -15 | anexar
# El span en error más profundo que sale del servicio hacia otro (CLIENT): es
# donde se rompe la cadena. Si no hay ninguno, el último span en error.
CULPABLE="$(jq -r '[.trace.resourceSpans[] | (.resource.attributes[] | select(.key=="service.name") | .value.stringValue) as $s
        | .scopeSpans[].spans[] | select((.status.code // "") | test("ERROR"))
        | {s: $s, n: .name, k: (.kind // ""), i: (.startTimeUnixNano|tonumber),
           ms: (((.endTimeUnixNano|tonumber) - (.startTimeUnixNano|tonumber)) / 1e6),
           url: ([.attributes[]? | select(.key=="url.full" or .key=="http.url") | .value.stringValue] | first // "")}]
       | (map(select(.k == "SPAN_KIND_CLIENT")) | sort_by(.i) | last) // (sort_by(.i) | last)
       | "\(.s) · \(.n) · \(.ms | floor) ms · \(.url)"' "/tmp/recorrido-traza-$$.json")"
rm -f "/tmp/recorrido-traza-$$.json"
T2=$(ahora_epoch)
marca "2·trazas" "✓ el primer span que falla: ${CULPABLE} · +$(( T2 - T0 )) s"

# --- 3 · Registros: ¿por qué? -------------------------------------------------
LINEA="$(loki_consulta "{k8s_namespace_name=\"${NS}\", service_name=\"${SERVICIO}\"} |= \"${TRAZA}\" | json | level=\"error\"" $(( AHORA - 900 )) "$(( $(ahora_epoch) + 5 ))" \
         | jq -c 'select(."url.full" != null or ."error.type" != null)' | head -1)"
[[ -n "$LINEA" ]] || LINEA="$(loki_consulta "{k8s_namespace_name=\"${NS}\", service_name=\"${SERVICIO}\"} |= \"${TRAZA}\" | json | level=\"error\"" $(( AHORA - 900 )) "$(( $(ahora_epoch) + 5 ))" | head -1)"
[[ -n "$LINEA" ]] || fallar "Loki no tiene registros de error con trace_id ${TRAZA}"
T3=$(ahora_epoch)
marca "3·registros" "registro del error con el mismo trace_id:"
jq . <<<"$LINEA" | anexar
marca "3·registros" "✓ causa: $(jq -r '"\(.message) — \(."upstream.service" // "") \(."url.full" // "") · \(."error.type" // "") \(."error.message" // "") · timeout \(.timeout_s // "-") s"' <<<"$LINEA") · +$(( T3 - T0 )) s"

DURACION=$(( T3 - T0 ))
marca "recorrido" "■ alerta → registro del error en ${DURACION} s (objetivo del criterio 2.4: < 180 s) · alerta sonando desde ${DESDE_ALERTA}"
echo "$DURACION" >"${REGISTRO%.log}.segundos"
