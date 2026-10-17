# Runbook · `CatalogoPresupuestoQuemaRapida`

| | |
|---|---|
| **Severidad** | `pagina` — se atiende de inmediato, a cualquier hora |
| **SLO** | `catalogo-latencia` · 99 % de las consultas al catálogo respondidas bien y en menos de 300 ms · 30 días |
| **Condición** | tasa de quema > 14,4 en la última hora **y** en los últimos 5 minutos, sostenida 2 minutos |
| **Regla** | [`observabilidad/config/slo/reglas-slo.yaml`](https://github.com/marcosbondel/sa-gitops-202202410/blob/main/observabilidad/config/slo/reglas-slo.yaml) |

## Qué está pasando, en una frase

**Navegar la tienda se volvió lento o falla: más de una de cada siete
consultas al catálogo tarda más de 300 ms o da error, y a este ritmo el margen
del mes se acaba en dos días.**

## Por qué amerita despertar a alguien

El catálogo es lo primero que ve un cliente y lo que más usa: si tarda, el
cliente se va antes de llegar a comprar, y eso no aparece como error en
ninguna parte —solo como ventas que no ocurrieron—. Con 14,4 de quema el
presupuesto del mes dura dos días; no hay ninguna acción automática que lo
corrija.

## Los primeros tres minutos: de la alerta a la causa

1. **Métricas — ¿lento o fallando? ¿quién?**
   Tablero, fila *2 · Latencia*:
   - *p95 que ve el cliente, por operación*: confirma que es
     `/api/catalog/graphql`.
   - *p95 por servicio*: si catalog-service también subió, el problema está
     en el catálogo o en su base; si solo subió el gateway, está en el
     gateway (autenticación contra auth-service, CPU).
   Fila *4 · Errores*: ¿hay 5xx o solo lentitud?
   Fila *5 · Saturación*: CPU de catalog-service contra su límite.

2. **Trazas — ¿en qué paso se va el tiempo?**
   Tempo, últimos 15 minutos, las consultas lentas:
   ```
   { resource.service.name = "catalog-service" && duration > 300ms }
   ```
   En la cascada, el span más largo es la respuesta: si son los spans `pg`
   (consultas SQL), es la base; si es el span de GraphQL sin hijos lentos, es
   CPU del propio servicio; si el tiempo está en el gateway antes de llegar
   al catálogo, es la introspección contra auth-service (span `POST` hacia
   `/api/auth/introspect`).

3. **Registros — ¿por qué?**
   *Logs for this span* sobre el span lento o fallido. Para los errores de
   GraphQL (que Apollo responde con HTTP 200), el registro
   `error en la operación GraphQL` lleva la operación y la excepción.

## Qué hacer

| Causa | Acción |
|---|---|
| Un cambio reciente en `envs/prod/` (versión o configuración) coincide | Revertir el commit en GitOps. |
| CPU de catalog-service al límite / HPA al máximo | Subir `maxReplicas` o `limits` por Pull Request. |
| Consultas SQL lentas | Revisar PostgreSQL (`sa-platform-postgresql-0`): conexiones, disco. Es compartido con los demás servicios: ver si el checkout también se degrada. |
| Introspección lenta en el gateway | auth-service saturado o caído: revisar sus pods; la caché del gateway (30 s) amortigua solo a usuarios ya vistos. |

## Cómo saber que terminó

El p95 del catálogo vuelve por debajo de 300 ms, la tasa de quema de 5
minutos baja de 14,4 y la alerta se resuelve. Registrar inicio, alerta,
recuperación y presupuesto consumido.
