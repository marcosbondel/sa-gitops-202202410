# Guion del video (5 a 8 minutos)

Preparación, antes de grabar:

```bash
P9/scripts/encender.sh                      # si el clúster está apagado (~35 min)
kubectl -n observabilidad port-forward svc/alertmanager-operated 9093:9093 &
# Grafana es público y de solo lectura: http://grafana.35.253.196.204.nip.io
# Tienda: http://sa-p9.35.253.196.204.nip.io · para editar en Grafana:
#   kubectl -n observabilidad get secret grafana-admin -o jsonpath='{.data.admin-password}' | base64 -d
```

Para el bloque 4 hace falta una versión defectuosa lista para fusionar
(`git tag p8-vX.Y.Z-fallo && git push origin p8-vX.Y.Z-fallo` → el pipeline
abre el Pull Request) y para el bloque 5, la alerta sonando: lanzar
`P10/scripts/incidente.sh` unos 8 minutos antes de grabar ese bloque, o
grabarlo sobre la evidencia ya registrada.

| Minuto | Punto demostrado | Qué se muestra |
|---|---|---|
| 0:00 – 0:40 | Contexto | La pregunta de la práctica: qué falla, por qué y si vale la pena intervenir. Diagrama de `docs/02-diagrama-telemetria.md`: tres señales, tres caminos, un `trace_id`. |
| 0:40 – 1:40 | **Instrumentación y correlación (2.1)** | `P10/servicios/*/src/telemetria/` y `order-service/app/telemetria.py`. En Grafana → Explore → Tempo: una compra, una sola traza gateway → order-service → catalog-service → PostgreSQL → RabbitMQ. «Logs for this span»: los registros de los tres servicios con el mismo `trace_id`. |
| 1:40 – 2:20 | **Registros estructurados (2.5)** | `kubectl -n sa-p8-prod logs deploy/sa-platform-order-service --tail=3`: JSON con `trace_id`. En Loki: `{service_name="order-service"} \| json \| level="error"` — consulta por campo. |
| 2:20 – 3:10 | **SLO y tablero (1.1, 1.2, 2.3)** | Tablero *Operación*: fila 1 (los dos SLO y el presupuesto que queda), filas 2–5 por señal de oro, cada panel con la pregunta que responde. `reglas-slo.yaml`: reglas de registro y las cuatro alertas por quema, con `runbook_url`. Métricas de negocio: pedidos, pagos, ventas, compras perdidas por motivo. |
| 3:10 – 4:40 | **Canary gobernado por métricas (2.2)** | `charts/sa-p10-analisis`: la plantilla consulta Prometheus filtrando por `rollouts_pod_template_hash`. Fusionar el PR de la versión `-fallo`. En el tablero, panel *api-gateway: errores por versión*: la candidata sube a ~30 %. `kubectl argo rollouts get rollout sa-platform-api-gateway -n sa-p8-stage --watch`: el AnalysisRun falla y el Rollout aborta solo. |
| 4:40 – 6:40 | **Del síntoma a la causa (2.4)** — cronómetro en pantalla | La alerta `CheckoutPresupuestoQuemaRapida` en Alertmanager → runbook → tablero, fila 4 (5xx en order-service, motivo `catalog_no_disponible`) → Tempo `{ resource.service.name = "order-service" && status = error }`: el span hacia catalog-service dura 5 s y falla, `url.full` con el puerto 4001 → «Logs for this span» → el registro `llamada a catalog-service fallida`, `error.type: ConnectTimeout`. Mientras tanto: los pods `Ready` y ArgoCD `Healthy`. Revertir el commit en GitOps. |
| 6:40 – 7:30 | **Informe y cierre (1.3)** | `docs/03-informe-operacion.md`: tiempos medidos, la alerta que faltó (gateway caído entero = silencio) y la mejora propuesta (contadores de error inicializados en cero). |

## Minutaje para la tabla del README

Llenar con los tiempos reales del video publicado:

| Punto | Minuto |
|---|---|
| Instrumentación y traza de punta a punta | ⏳ |
| Registros JSON consultables por campo | ⏳ |
| SLO, reglas y tablero | ⏳ |
| Reversión del canary por métricas | ⏳ |
| Recorrido alerta → traza → registro, cronometrado | ⏳ |
| Informe de operación | ⏳ |
