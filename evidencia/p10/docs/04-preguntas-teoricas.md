# Preguntas teóricas: cómo se comporta esta instrumentación y dónde no alcanza

Respuestas sobre **este** sistema, con lo que se midió en él. Cada una
termina en el límite que tiene.

---

### 1. ¿Por qué el SLO se mide en el gateway y no en el cliente?

Porque el gateway es lo más cerca del cliente que este sistema controla: ve
cada petición, con su resultado y su duración, sin importar qué servicio la
atendió. Medir en order-service dejaría fuera los fallos del gateway y de la
autenticación; medir CPU o pods `Ready` mediría lo que el sistema dice de sí
mismo, que es justo lo que el incidente de producción demostró que miente
(order-service `Ready`, ArgoCD `Healthy`, y todas las compras fallando).

**Límite.** Lo que falla ANTES del gateway no existe para el SLO: el
balanceador de GCP, ingress-nginx, el DNS de `nip.io`. Y si **todos** los
pods del gateway caen, la métrica no dice «100 % de errores»: deja de
existir, el SLI queda vacío y **ninguna alerta suena**. Las dos mejoras
posibles: medir también en ingress-nginx (que respondería 503 y lo contaría)
o una sonda sintética desde fuera del clúster; y una regla `absent()` sobre
el tráfico del gateway.

### 2. ¿Por qué alertas por tasa de quema y no «errores > 5 %»?

Un umbral instantáneo no sabe cuánto importa lo que ve. Un 5 % de errores
durante 30 segundos en una recarga de nginx no merece despertar a nadie; un
0,8 % sostenido toda la noche agota el presupuesto del mes y nadie se
entera. La tasa de quema traduce cualquier nivel de error a la única pregunta
que importa —¿a este ritmo, cuándo incumplimos?— y la doble ventana separa lo
real (1 h) de lo actual (5 min).

Los números salen de la ventana de 30 días: 14,4 × 1 h = 2 % del presupuesto
(720 h × 2 % = 14,4 h de presupuesto «normal» gastadas en una); 6 × 6 h = 5 %.

**Límite, medido.** La alerta rápida no puede sonar antes de que el error
acumule el 7,2 % de la última hora (14,4 × 0,5 %). Con el 100 % de las compras
fallando son ~4,3 min, más los 2 min de `for`: unos 6 a 7 min desde el inicio
del fallo en un sistema con una hora de historia sana. Es el precio de no
despertar a nadie por un pico.

### 3. ¿Qué hace el canary si Prometheus no responde?

Cada medición fallaría con error de consulta; Argo Rollouts marca la métrica
como `Error` y, tras cuatro errores consecutivos, el AnalysisRun entero
pasa a `Error`, lo que **aborta** el rollout. Es la falla segura correcta:
sin evidencia, no se promueve. La métrica `trafico` hace lo mismo en el caso
más sutil —Prometheus responde, pero la versión candidata no recibe
peticiones—: «0 % de errores» sin tráfico no prueba nada.

**Límite.** Un Prometheus caído bloquea todas las entregas del gateway. Es
deliberado, pero hace a Prometheus (una réplica) parte del camino crítico de
despliegue.

### 4. ¿Por qué la primera medición del canary defectuoso vio 0 % de errores?

Porque el contador `http_server_request_duration_seconds_count{…status="500"}`
de la versión candidata **no existía** hasta el primer 500, y Prometheus
raspa cada 15 s: la serie apareció ya con valor 6. `rate()` solo cuenta
incrementos ENTRE muestras, así que esos seis primeros errores no existieron
para la consulta. La segunda medición, un minuto después, ya vio 15 %.

Es un defecto de la instrumentación, no del análisis, y está medido en
`docs/evidencias/canary-fallo-*.log`. La corrección es inicializar en cero las
combinaciones conocidas (`http.route` × «5xx») al arrancar el proceso; habría
adelantado la detección una medición (~1 min). Es la mejora propuesta en el
informe.

### 5. ¿Cómo se propaga el contexto entre Node y Python?

Por la cabecera W3C `traceparent` (`00-<trace_id>-<span_id>-01`). La
instrumentación de `http` del gateway la inyecta en la petición que el proxy
manda a order-service; la de FastAPI la extrae y crea el span hijo; la de
`httpx` la vuelve a inyectar hacia catalog-service. Los tres declaran
explícitamente el mismo propagador (`TraceContext` + `Baggage`), porque es
un contrato entre lenguajes.

**Límite.** La traza termina en la publicación a RabbitMQ: aio-pika escribe
el contexto en las cabeceras del mensaje, pero el consumidor
(notification-worker) no está instrumentado y no lo lee. Lo que pasa con la
notificación de un pedido queda fuera de su traza.

### 6. ¿Por qué los registros salen por stdout y no por OTLP?

Para que la aplicación no dependa de nada para dejar rastro de su propio
fallo. Si el Collector o Loki caen, `kubectl logs` sigue mostrando las líneas
JSON; con OTLP directo, un Collector caído se llevaría también los registros
del momento en que más se necesitan. El Collector los lee del disco del nodo
y, si Loki no responde, reintenta desde el último punto leído.

**Límite.** Si el archivo de log del contenedor rota mientras Loki está caído,
lo rotado se pierde para la consulta centralizada.

### 7. ¿Qué etiqueta podría tumbar a Prometheus?

Cualquiera con un valor distinto por petición: el `trace_id`, el `order_id`
dentro de la ruta, el `user_id`. Por eso `http.route` se **normaliza**
(`/api/orders/{id}/pay`), el `trace_id` va a los registros y a Tempo pero
nunca a una métrica, y en Loki el `trace_id` es metadato estructurado, no
etiqueta de índice. Las etiquetas que sí se agregaron (`pod`,
`rollouts_pod_template_hash`) tienen tantos valores como pods vivos.

### 8. ¿Por qué el canary no protegió del incidente de producción?

Porque protege una cosa: las **versiones nuevas del gateway**. El incidente
fue un cambio de **configuración** de **order-service**, que es un Deployment
con actualización progresiva normal. Kubernetes reemplazó los pods, los
nuevos pasaron la readiness —que consulta PostgreSQL, no al catálogo— y la
actualización se dio por buena. Lo vio el SLO, porque mide el resultado, no
el mecanismo. Por eso hacen falta las dos cosas.

### 9. ¿Qué pasa si se cae el propio stack de observabilidad?

Prometheus, Loki, Tempo y Alertmanager tienen una réplica cada uno. Si cae
Prometheus no hay alertas —y nadie se entera, porque la alerta `Watchdog`
del chart (la «señal de vida» que debe sonar siempre para que su silencio
sea la alarma) se eliminó junto con las demás alertas genéricas: sin un
receptor externo que note su ausencia, no servía de nada—. Es la limitación
más seria de esta entrega: en producción real, Alertmanager mandaría el
`Watchdog` a un servicio externo de «dead man's switch».

### 10. ¿Se muestrean las trazas?

No: se guardan todas (`parentbased_always_on`). Y ya costó algo, medido: con
~10 peticiones por segundo y ~40 spans por compra, **Tempo murió por OOM**
(límite de 1 GiB) a las 13:20 UTC del 2026-10-17, al cerrar un bloque de
30 minutos de trazas. Se corrigió por GitOps —2 GiB y bloques de 5 min— y el
pod, atascado en `CrashLoopBackOff`, hubo que borrarlo a mano porque un
StatefulSet `OrderedReady` no reemplaza un pod que nunca llega a `Ready`.

Dos lecciones. La primera, que la mitad de esos spans no dicen nada:
`middleware - corsMiddleware`, `middleware - query`, cada campo trivial de
GraphQL; la instrumentación de Express permite ignorar las capas de
middleware y es la mejora más barata. La segunda, que con tráfico real habría
que muestrear, y la forma correcta no es al principio (que tiraría al azar
justo la traza del error) sino en el Collector, después de ver la traza
completa (*tail sampling*): quedarse con todas las que tienen error o son
lentas, y con un porcentaje de las demás.

### 11. El p95 del canary, ¿es confiable?

Con pocas peticiones, no del todo: con 20 observaciones en la ventana, el p95
es prácticamente la más lenta. La primera medición del canary defectuoso dio
0,53 s solo porque en la ventana entraron dos compras —que tardan ~0,34 s—
de un pod recién arrancado. Por eso cada métrica tolera **una** medición
fallida (`failureLimit: 1`) y el análisis exige tráfico mínimo: el ruido de
una medición no revierte una entrega sana; dos seguidas sí.
