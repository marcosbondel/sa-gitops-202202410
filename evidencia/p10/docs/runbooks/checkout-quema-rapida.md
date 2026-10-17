# Runbook · `CheckoutPresupuestoQuemaRapida`

| | |
|---|---|
| **Severidad** | `pagina` — se atiende de inmediato, a cualquier hora |
| **SLO** | `checkout-disponibilidad` · 99,5 % de los intentos de compra sin error del sistema · 30 días |
| **Condición** | tasa de quema > 14,4 en la última hora **y** en los últimos 5 minutos, sostenida 2 minutos |
| **Regla** | [`observabilidad/config/slo/reglas-slo.yaml`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/observabilidad/config/slo/reglas-slo.yaml) |
| **Tablero** | Grafana → *Operación — tienda en línea (Práctica 10)* |

## Qué está pasando, en una frase

**Una parte importante de los clientes que intentan comprar recibe un error,
y a este ritmo el margen de fallos de todo el mes se acaba en menos de dos
días.**

## Por qué amerita despertar a alguien

Una tasa de quema de 14,4 significa que en una hora se gastó el 2 % del
presupuesto del mes. No es un pico: la ventana de una hora confirma que lleva
rato, y la de cinco minutos, que sigue ocurriendo **ahora**. Cada minuto que
pasa son compras que no se hicieron —dinero que no entra— y, si nadie actúa,
en dos días el sistema habrá incumplido lo que promete. No hay ninguna
acción automática que lo resuelva: el canary solo protege los despliegues del
gateway, y este fallo puede venir de cualquier otro lado.

## Los primeros tres minutos: de la alerta a la causa

El objetivo es llegar al **registro del error** usando las tres señales, sin
revisar servicio por servicio.

1. **Métricas — ¿dónde?** (≈ 30 s)
   Tablero → fila *4 · Errores*.
   - *Respuestas con error del sistema, por servicio*: ¿solo el gateway, o
     también order-service? Si order-service está en 5xx, el gateway solo
     está reenviando el error de abajo.
   - *Compras perdidas, por motivo*: `catalog_no_disponible` dice que
     order-service no pudo hablar con catalog-service. Ausencia de motivo con
     5xx en el gateway apunta al propio gateway o a auth-service.
   - Fila *5 · Saturación*: ¿algún servicio en el 100 % de CPU o memoria, o
     en su máximo de réplicas?

2. **Trazas — ¿qué petición y en qué paso?** (≈ 1 min)
   Grafana → *Explore* → **Tempo** → TraceQL, últimos 15 minutos:

   ```
   { resource.service.name = "order-service" && span.http.route = "/api/orders" && status = error }
   ```

   Abrir una traza. La cascada muestra el recorrido completo
   `api-gateway → order-service → catalog-service / PostgreSQL / RabbitMQ`.
   El span en rojo que está más abajo es el que falló primero; su duración
   dice si fue un rechazo inmediato o una espera hasta el *timeout* (5 s
   hacia el catálogo), y sus atributos (`url.full`, `server.port`,
   `error.type`) dicen contra qué.

3. **Registros — ¿por qué?** (≈ 30 s)
   En ese span → **Logs for this span**. Loki abre los registros de ese
   servicio con el mismo `trace_id`. El de nivel `error` trae la causa en
   campos: `upstream.service`, `url.full`, `timeout_s`, `error.type`,
   `error.message`, y la pila si fue una excepción no controlada.

   La consulta equivalente, por si se llega desde Loki:

   ```
   {k8s_namespace_name="sa-p8-prod", service_name="order-service"} | json | level="error"
   ```

## Qué hacer según lo que se encontró

| Causa encontrada | Acción |
|---|---|
| Un cambio reciente en `envs/prod/` del repositorio GitOps (configuración, versión de imagen) coincide con el inicio de la quema | **Revertir el commit** en GitOps (`git revert` + Pull Request). ArgoCD aplica la versión anterior en ~1 min. No editar el clúster a mano: ArgoCD lo deshace (`selfHeal`). |
| catalog-service o order-service sin réplicas listas, `CrashLoopBackOff` | `kubectl -n sa-p8-prod describe pod …` y `kubectl logs --previous`. Si es la imagen, revertir su versión en GitOps. |
| PostgreSQL caído o lleno (`sa-platform-postgresql-0`) | Es un punto único de fallo declarado en la P9. Si el volumen se corrompió: `P9/docs/03-runbook-recuperacion.md`, restauración desde Velero. |
| Servicio saturado (CPU al límite, réplicas al máximo del HPA) | Subir `maxReplicas` o `limits` en `envs/prod/values.yaml` por Pull Request. |
| Errores solo en la versión candidata de un canary del gateway | No hacer nada: el análisis lo revierte solo. Confirmar con `kubectl argo rollouts get rollout sa-platform-api-gateway -n sa-p8-prod`. |

## Cómo saber que terminó

- La tasa de quema de 5 minutos baja de 14,4 (panel *¿A qué velocidad se gasta
  el presupuesto?*) y la alerta se resuelve sola en Alertmanager.
- *Compras exitosas · última hora* vuelve a crecer y *Compras perdidas* con
  motivo de sistema vuelve a cero.
- Anotar en el informe del incidente la hora de inicio (primer 5xx en el
  panel), la de la alerta y la de la recuperación, y cuánto presupuesto se
  gastó (*Presupuesto de error del checkout que queda*, antes y después).

## Si el presupuesto del mes ya se agotó

Congelar despliegues que no sean correcciones hasta que la ventana de 30 días
lo recupere. Es la consecuencia acordada de incumplir el SLO, y la razón de
medirlo.
