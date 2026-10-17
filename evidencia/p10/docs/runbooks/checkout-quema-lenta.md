# Runbook · `CheckoutPresupuestoQuemaLenta`

| | |
|---|---|
| **Severidad** | `ticket` — se atiende en el siguiente horario laboral, el mismo día |
| **SLO** | `checkout-disponibilidad` · 99,5 % de los intentos de compra sin error del sistema · 30 días |
| **Condición** | tasa de quema > 6 en las últimas 6 horas **y** en los últimos 30 minutos, sostenida 5 minutos |
| **Regla** | [`observabilidad/config/slo/reglas-slo.yaml`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/observabilidad/config/slo/reglas-slo.yaml) |
| **Se silencia sola** | si la de quema rápida del mismo SLO ya está sonando (regla de inhibición de Alertmanager) |

## Qué está pasando, en una frase

**Una fracción pequeña pero constante de las compras falla desde hace horas;
si sigue así, el margen de fallos del mes se acaba en unos cinco días.**

## Por qué amerita intervención, pero no de madrugada

Una tasa de 6 sostenida seis horas es el 5 % del presupuesto del mes. Ningún
cliente concreto nota algo grave —quizá uno de cada cincuenta reintenta—, pero
sumado es un incumplimiento seguro antes de fin de semana. Hay tiempo para
atenderlo con calma; no lo hay para ignorarlo. Si nadie lo atiende, se
convierte en la alerta rápida cuando ya sea tarde para corregir con calma.

## Cómo encontrar la causa

Los fallos lentos casi nunca están en todas las peticiones: hay que buscar
**qué tienen en común las que fallan**.

1. **Métricas.** Tablero, fila *4 · Errores*, con el rango en **últimas
   6 horas**:
   - *Compras perdidas, por motivo*: ¿un motivo dominante?
   - *Respuestas con error del sistema, por servicio*: ¿un servicio o todos?
   - *api-gateway: errores por versión*: ¿los errores vienen de una sola
     versión del gateway (un ReplicaSet viejo que quedó vivo)?
   - Fila *5 · Saturación*: ¿coinciden los errores con picos de CPU o con el
     HPA en su máximo? Un fallo lento típico es la saturación en horas pico.
2. **Trazas.** Tempo, últimas 6 horas, y agrupar mentalmente por lo que
   tienen en común:
   ```
   { resource.service.name = "order-service" && status = error }
   ```
   Mirar varias: ¿siempre el mismo producto? ¿el mismo pod
   (`k8s.pod.name`)? ¿siempre tras ~5 s (timeout) o inmediatas?
3. **Registros.** Desde un span, *Logs for this span*. Para contar los
   errores por tipo en todo el periodo:
   ```
   sum by (error_type) (count_over_time({k8s_namespace_name="sa-p8-prod", service_name="order-service"} | json | level="error" [6h]))
   ```

## Qué hacer

| Si los errores… | Entonces |
|---|---|
| vienen de un solo pod | `kubectl -n sa-p8-prod delete pod <pod>`; el Deployment crea otro. Abrir un ticket para entender por qué ese pod se degradó (memoria, conexión a la base). |
| coinciden con saturación | Subir `maxReplicas`/`limits` por Pull Request en `envs/prod/values.yaml`. |
| vienen de un producto o una operación concreta | Es un defecto de código: issue al repositorio de código con el `trace_id` de ejemplo y el registro de error. |
| son timeouts esporádicos hacia catalog-service o PostgreSQL | Revisar la latencia p95 por servicio (fila *2*); si la base se degrada, ver el runbook de recuperación de la P9. |

## Cómo saber que terminó

La tasa de quema de 30 minutos baja de 6 y la alerta se resuelve. Registrar
en el ticket la causa y cuánto presupuesto se consumió en el periodo.
