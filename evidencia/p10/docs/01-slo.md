# Los dos SLO: qué se promete, durante cuánto tiempo y por qué ese número

Un SLO es una promesa hecha **desde el punto de vista del cliente**. Por eso
los dos se miden en el `api-gateway` —el primer servicio propio que toca cada
petición— y no en la CPU de un nodo ni en el estado de un pod: un pod `Ready`
que responde 503 no es «disponible» para nadie.

| | SLO 1 · Las compras se completan | SLO 2 · El catálogo responde rápido |
|---|---|---|
| **Promesa, en palabras de cliente** | «Cuando intento comprar, mi pedido se registra.» | «Cuando busco productos, la página responde enseguida.» |
| **Objetivo** | **99,5 %** de los intentos de compra sin error del sistema | **99 %** de las consultas respondidas bien y en **menos de 300 ms** |
| **Ventana** | **30 días móviles** | **30 días móviles** |
| **Evento bueno** | `POST /api/orders` con estado **< 500** | petición a `/api/catalog/*` con estado < 500 **y** en el cubo `le="0.3"` |
| **Evento malo** | respuesta 5xx (error del sistema) | respuesta 5xx **o** lenta (≥ 300 ms) |
| **No cuenta** | 4xx: carrito vacío, producto inexistente — la petición estaba mal, el sistema respondió bien | — |
| **Presupuesto de error** | 0,5 % → ~3 h 36 min al mes de compras imposibles | 1 % → ~7 h 12 min al mes de catálogo lento |
| **SLI (regla de registro)** | `sli:checkout_disponibilidad:ratio_rate5m` · `…_rate30d` | `sli:catalogo_latencia:ratio_rate5m` · `…_rate30d` |
| **Presupuesto consumido** | `slo:checkout_disponibilidad:presupuesto_consumido:ratio30d` | `slo:catalogo_latencia:presupuesto_consumido:ratio30d` |

Reglas: [`observabilidad/config/slo/reglas-slo.yaml`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/observabilidad/config/slo/reglas-slo.yaml).

## La línea base: lo que el sistema hace hoy

Medido en el gateway de stage con la versión 1.3.1, el 2026-10-17 entre las
12:50 y las 12:58 UTC, con el simulador de clientes a ~4 peticiones por
segundo (ver `simulador/usuarios.js` en el repositorio GitOps):

| | p50 | p95 | p99 | bajo 300 ms | bajo 100 ms | 5xx |
|---|---|---|---|---|---|---|
| Catálogo (`/api/catalog/graphql`) | 18 ms | 30 ms | 49 ms | **100 %** | 99,7 % | 0 |
| Compra (`POST /api/orders`) | — | 342 ms | — | — | — | **0** de 119 (113 × 201, 6 × 400) |

Los 6 × 400 son los pedidos con un producto inexistente que el simulador
manda a propósito (4 %): rechazos legítimos que **no** consumen presupuesto.

## Por qué 99,5 % y no otro número (SLO 1)

**No 100 %.** Ningún sistema lo cumple, y prometerlo deja sin margen para
desplegar: cada versión nueva, cada reinicio de nodo, cada recarga de nginx
durante un canary produce algún error aislado. Un presupuesto de cero
significaría congelar los cambios para siempre.

**No 99,9 %.** Son 43 minutos al mes. La Práctica 9 midió el peor caso que
este sistema sabe recuperar —perder el clúster entero— en **29 minutos** de
RTO, y declaró que PostgreSQL y RabbitMQ son puntos únicos de fallo con una
réplica cada uno: un solo incidente de ese tipo gastaría dos tercios del
presupuesto anual… del mes. Prometer 99,9 % sería prometer algo que la
arquitectura actual no puede sostener, y un SLO que se incumple siempre deja
de servir para decidir nada.

**99,5 %** son 3 h 36 min al mes. Caben un desastre total (29 min) y varias
degradaciones menores, y aun así un fallo que afecte a todas las compras se
nota: lo agota en tres horas y media. Es también lo que la cadena de
dependencias de una compra puede dar: gateway → auth-service → order-service
→ catalog-service → PostgreSQL → RabbitMQ, seis componentes en serie; con
cada uno al 99,9 %, la compra completa queda en ~99,4 %. Prometer más que el
producto de las partes sería prometer suerte.

**Por qué solo la compra.** Es la operación en la que un error le cuesta
dinero al negocio y frustración al cliente en el momento más delicado. Un
error al listar notificaciones también es un error, pero el cliente
reintenta y nada se pierde.

## Por qué 99 % por debajo de 300 ms (SLO 2)

**300 ms** es lo que puede tardar el servidor para que la página siga
sintiéndose fluida. Los clientes están en Guatemala y el clúster en
`us-central1`: el viaje de ida y vuelta por la red ya cuesta del orden de
100 a 150 ms, y el navegador necesita su parte para pintar. Con 300 ms en el
servidor, el total queda por debajo del segundo, que es el límite clásico a
partir del cual una persona pierde el hilo de lo que estaba haciendo.

**No 100 ms**, aunque hoy el 99,7 % lo cumple: es el comportamiento en
reposo, con la base caliente y sin carga. Un umbral pegado a la línea base
alertaría por cada pico de tráfico normal —el HPA tarda un minuto en añadir
réplicas— y el presupuesto se gastaría en ruido que ningún cliente nota.

**99 % y no 99,5 %.** La latencia es más ruidosa que la disponibilidad: una
recolección de basura, un pod que arranca, la primera consulta tras un
reinicio. Un 1 % de consultas lentas es tolerable; un 1 % de compras fallidas
no lo sería. Y el catálogo es solo lectura: una consulta lenta no deja nada a
medias.

**Por qué el cubo `le="0.3"` existe.** Los cortes del histograma de los tres
servicios incluyen 0,3 s a propósito (`telemetria/metricas.ts`). Si no
existiera, Prometheus tendría que interpolar entre 0,2 y 0,5 y el SLI dejaría
de ser una cuenta para ser una estimación.

## Por qué 30 días

Es el periodo en el que el negocio piensa (el mes) y lo bastante largo para
que un solo mal día no lo decida todo. Una ventana de 7 días haría que un
incidente de un lunes dominara el número toda la semana; una de 90 días
diluiría cualquier incidente hasta hacerlo invisible.

**Limitación declarada:** el clúster se apaga entre sesiones para no pagarlo
(`P9/scripts/apagar.sh`), y el disco de Prometheus no se respalda. La ventana
de 30 días cubre, en la práctica, desde el último encendido. Las reglas no
cambian —un `rate(…[30d])` sobre menos datos sigue siendo la proporción de
eventos buenos entre los que hubo—, pero el número del tablero describe «desde
que se encendió», no «el último mes». En producción real Prometheus no se
apaga, y el historial largo iría a un almacenamiento remoto (Thanos o
Managed Service for Prometheus).

## Cómo se convierten en alertas

Por **tasa de quema** (cuántas veces más rápido de lo sostenible se gasta el
presupuesto), en dos ventanas, siguiendo el SRE Workbook:

| Alerta | Ventanas | Quema | Significa | Severidad |
|---|---|---|---|---|
| `*PresupuestoQuemaRapida` | 1 h **y** 5 min | > 14,4 | 2 % del mes en 1 h: se agota en 2 días | `pagina` |
| `*PresupuestoQuemaLenta` | 6 h **y** 30 min | > 6 | 5 % del mes en 6 h: se agota en 5 días | `ticket` |

Cada una con su runbook en [`runbooks/`](runbooks/). Ninguna por umbral
instantáneo: ver el encabezado de las reglas.
