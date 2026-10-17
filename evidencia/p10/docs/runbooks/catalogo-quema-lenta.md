# Runbook · `CatalogoPresupuestoQuemaLenta`

| | |
|---|---|
| **Severidad** | `ticket` — se atiende en el siguiente horario laboral, el mismo día |
| **SLO** | `catalogo-latencia` · 99 % de las consultas al catálogo respondidas bien y en menos de 300 ms · 30 días |
| **Condición** | tasa de quema > 6 en las últimas 6 horas **y** en los últimos 30 minutos, sostenida 5 minutos |
| **Se silencia sola** | si la de quema rápida del mismo SLO ya está sonando |

## Qué está pasando, en una frase

**Desde hace horas, una parte pequeña pero constante de las consultas al
catálogo tarda más de 300 ms; si sigue así, el margen del mes se acaba en unos
cinco días.**

## Por qué amerita intervención, pero no de madrugada

Es la degradación que nadie reporta: ningún cliente llama para decir que la
página tardó medio segundo, simplemente compra menos. Seis horas a 6× son el
5 % del presupuesto mensual. Se atiende con calma, pero se atiende: la
lentitud gradual suele crecer (tablas que crecen, memoria que se fragmenta) y
termina en la alerta rápida.

## Cómo encontrar la causa

1. **Métricas.** Tablero con rango **últimas 24 horas**:
   - *p95 por servicio*: ¿la subida es gradual (crecimiento de datos, fuga)
     o en escalones (un despliegue)? Un escalón que coincide con un cambio en
     `envs/prod/` es la causa más probable.
   - *Peticiones por segundo*: ¿la lentitud sigue al tráfico? Entonces es
     capacidad, no un defecto.
   - *CPU / memoria sobre el límite*: una memoria que sube sin bajar es una
     fuga.
2. **Trazas.** Tempo:
   ```
   { resource.service.name = "catalog-service" && duration > 300ms }
   ```
   Comparar varias trazas lentas: ¿siempre la misma consulta SQL? ¿el mismo
   pod? ¿la misma operación GraphQL?
3. **Registros.** Desde el span, *Logs for this span*; buscar advertencias
   del pool de PostgreSQL (`PostgreSQL no responde`, `error inesperado en el
   pool`).

## Qué hacer

| Si… | Entonces |
|---|---|
| la lentitud empezó con un despliegue | Revertir en GitOps. |
| sigue al tráfico | Ajustar el HPA (`minReplicas`, `targetCPUUtilizationPercentage`) por Pull Request. |
| es una consulta SQL concreta | Issue al repositorio de código con el `trace_id` y el texto de la consulta del span `pg`. |
| la memoria crece sin parar | Reiniciar el Deployment como mitigación (`kubectl rollout restart`) y abrir un issue: es una fuga. |

## Cómo saber que terminó

La tasa de quema de 30 minutos baja de 6 y la alerta se resuelve. Registrar
en el ticket la causa y el presupuesto consumido.
