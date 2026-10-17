# Informe de operación — Práctica 10

**Carné 202202410 · 2026-10-17 · clúster `sa-p9` (GKE, us-central1-a) · todas las horas en UTC.**
Dos fallos inducidos, medidos con el cronómetro corriendo: **A**, una versión
defectuosa del gateway que el canary debía detener solo; **B**, un cambio de
configuración en producción que el canary no puede ver y que tenía que
encontrar una alerta. Registros completos en [`evidencias/`](evidencias/).

## 1 · SLO declarados

| SLO | Objetivo | Ventana | Por qué ese número ([detalle](01-slo.md)) |
|---|---|---|---|
| **Compras que se completan** (`POST /api/orders` sin 5xx, medido en el gateway) | **99,5 %** | 30 días | 99,9 % (43 min/mes) no cabe ni un desastre como el que la P9 midió (RTO 29 min) con PostgreSQL y RabbitMQ en una réplica; 100 % impide desplegar. Seis componentes en serie al 99,9 % dan ~99,4 %. Línea base: 0 errores en 119 compras. |
| **Catálogo rápido** (`/api/catalog/*` sin 5xx y < 300 ms) | **99 %** | 30 días | 300 ms en el servidor + ~150 ms de red desde Guatemala dejan la página bajo 1 s. Línea base: p99 49 ms, 100 % bajo 300 ms; un umbral de 100 ms gastaría presupuesto en picos que nadie nota. |

## 2 · Fallo inducido

| | Qué se rompió | Cómo se provocó |
|---|---|---|
| **A** (stage) | El gateway 1.3.2-fallo asume que todo cliente manda `Accept-Language`: a los que no (la «app móvil», 30 % del simulador) les responde 500. Distinto al de la P8, que rompía la **latencia**; este rompe la **tasa de errores**. Las sondas `/health` no pasan por esa ruta: el pod está `Ready`. | Por el camino real: `git tag p8-v1.3.2-fallo` → pipeline (Trivy, firma, verificación) → PR #12 en GitOps → fusión 12:59:19 ([parche](../fallo-inducido/api-gateway.patch)). |
| **B** (prod) | order-service busca el catálogo en el puerto **4001** en vez del 4000: cada compra espera 5 s y termina en 503. Kubernetes no lo ve: la readiness consulta PostgreSQL, los pods quedan `Ready` y ArgoCD `Synced/Healthy`. | Un commit en GitOps, 13:09:03 (`24b97ae`, «order-service apunta al nuevo puerto del catálogo»). Es un Deployment y un cambio de configuración: no pasa por el canary. |

## 3 · Tiempo de detección

| | Inicio del fallo | Primera señal | Tiempo |
|---|---|---|---|
| **A** | 12:59:39 — la versión candidata recibe tráfico (peso 10 %) | 13:02:39 — segunda medición fallida de `tasa-errores` (15,3 % y 30,7 %); AnalysisRun `sa-platform-api-gateway-7d7ffb5988-3-1` en `Failed` | **3 min 07 s** |
| **B** | 13:09:34.683 — primer registro de error de order-service (Loki) | 13:12:23 — `CheckoutPresupuestoQuemaRapida` firing (`startsAt` de Prometheus; en Alertmanager 13:12:25) | **2 min 49 s** |

Respaldo: `canary-fallo-20261017T125912Z.log` y `incidente-checkout-20261017T130858Z.log`.
En **B** la detección fue más rápida que en régimen: la ventana de 1 h tenía
solo ~13 min de historia sana. Con una hora completa, la regla exige que el
error acumule 14,4 × 0,5 % = 7,2 % de la hora (~4,3 min al 100 % de fallos) +
2 min de `for`: **unos 6½ min**.

## 4 · Recorrido hasta la causa (B)

Ejecutado con `scripts/recorrido.sh` (el procedimiento del
[runbook](runbooks/checkout-quema-rapida.md)) desde la alerta, **13:12:27 → 13:12:31: 4 s**.

1. **Alerta** (Alertmanager): `CheckoutPresupuestoQuemaRapida`, severidad `pagina`, SLO `checkout-disponibilidad`, enlace al runbook.
2. **Métricas** (Prometheus): 5xx en `api-gateway` (0,27/s) **y** en `order-service` (0,26/s) → el error nace en order-service; `pedidos_rechazados_total{motivo="catalog_no_disponible"}` = 15,6 compras perdidas por minuto.
3. **Traza** (Tempo, `{ resource.service.name = "order-service" && status = error }`): traza `8d0b6e9f…`; gateway 5 043 ms → order-service 5 034 ms → **`POST http://sa-platform-catalog-service:4001/graphql`, 5 004 ms, en error**.
4. **Registro** (Loki, mismo `trace_id`): `"llamada a catalog-service fallida: no respondió"`, `url.full: …:4001/graphql`, `error.type: ConnectTimeout`, `timeout_s: 5.0` → el puerto está mal → el último commit en `envs/prod/`.

Ningún paso revisó registros servicio por servicio: el `trace_id` llevó de la traza al registro. El mismo recorrido a mano en Grafana se muestra en el video (⏳ minutaje en el README).

## 5 · Tiempo de recuperación

| | Estable de nuevo | Quién / qué | Tiempo desde el inicio |
|---|---|---|---|
| **A** | 13:02:48 — 100 % del tráfico en la versión estable `5499d6b5c8`, candidata a 0 | **Argo Rollouts**, solo, al fallar el análisis. Después (13:02:58) el revert en Git para que GitOps declare la verdad. | **3 min 09 s** — sin intervención humana |
| **B** | 13:13:31.782 — primera compra con 201 tras revertir (último error 13:13:52, pods viejos drenando) | **El operador**: `git revert` de `24b97ae` a las 13:13:11 (40 s tras encontrar la causa); ArgoCD aplicó en 20 s. | **3 min 57 s** |

Costo de B: **119 compras fallidas** en 6 min. Al ritmo simulado (30 compras/min ≈ 1,3 M al
mes) el presupuesto mensual es ~6 480 compras: **~1,8 % del mes**. El tablero marca
un presupuesto negativo porque su ventana de 30 días solo contiene lo medido desde el
encendido de hoy (limitación declarada en [01-slo.md](01-slo.md)).

## 6 · Alerta faltante o sobrante

**Sobrante — `CheckoutPresupuestoQuemaLenta`.** Pasó a *firing* a las 13:15:30,
**dos minutos después** de que las compras ya se habían recuperado, y siguió
sonando ~30 min (su ventana corta es de 30 min). Mientras sonó la rápida
estuvo inhibida; al resolverse esta (13:18:45) quedó sola: un `ticket` para un
incidente cerrado. Es ruido. Ajuste: inhibirla también durante 1 h después de
que la rápida del mismo SLO se resuelva —o exigir `burnrate5m > 6` como tercera
condición, para que solo suene si sigue quemando *ahora*—.

**Faltante — el silencio del gateway caído.** Si todos los pods del gateway
cayeran, la métrica del SLO no marcaría 100 % de errores: dejaría de existir,
el SLI quedaría vacío y **ninguna alerta sonaría**. La señal que acortaría esa
detección es medir el SLI también en ingress-nginx (respondería 503 y lo
contaría) más una alerta `absent()` sobre el tráfico del gateway.

**Mejora propuesta a la propia instrumentación — contadores de error
inicializados en cero.** En A, la primera medición del análisis vio **0 %** de
errores con la candidata ya fallando: la serie `…_count{status="500"}` nació
con valor 6 y `rate()` no cuenta lo anterior a la primera muestra. Registrar en
cero, al arrancar, cada combinación conocida `http.route` × «500» haría que la
serie exista antes del primer error. Habría detectado A en la **primera**
medición: ~2 min en lugar de 3 min 07 s.
