# Informe de la prueba de recuperación ante desastres

**Sistema:** plataforma `sa-platform` (5 microservicios, PostgreSQL, RabbitMQ) en GKE · **Carné:** 202202410
**Prueba:** 2026-10-17, 04:20–05:07 UTC · **Registro:** [`evidencias/prueba-dr-20261017T042003Z.log`](evidencias/prueba-dr-20261017T042003Z.log) · datos crudos en la carpeta homónima

## 1. Objetivos declarados

Declarados antes de cualquier prueba en [`01-objetivos-rto-rpo.md`](01-objetivos-rto-rpo.md).

- **RTO = 40 min**: suma de las etapas del bootstrap, dominada por la creación del clúster de GKE (~10–12 min), más margen. Bajarlo exige un clúster de reserva encendido, que no se justifica sin usuarios reales.
- **RPO = 15 min**: frecuencia del Schedule `sa-p9-cada-15m`. Por debajo, GCP admite un snapshot por disco cada 10 min; por encima, se perderían más de 7 latidos de la plataforma.

## 2. Escenario ejecutado

Pérdida total del entorno de cómputo, sin apagado ordenado (`scripts/desastre.sh`), en este orden:

1. **04:34:57** — `terraform destroy` de `10-cluster`: plano de control, 3 nodos y todo lo que corría dentro (ArgoCD, plataforma, Velero, Kyverno, `Secret` descifrados, la llave en `kube-system`).
2. **04:43:47** — estado de `20-gitops` vaciado: describía un clúster que ya no existía.
3. **04:43:48–52** — los **4 discos** de datos borrados (PostgreSQL y RabbitMQ de stage y prod): los datos solo podían volver del respaldo.

Intacta, a propósito: la fundación (bucket, snapshots, Secret Manager, IP). Durante la prueba, un escritor insertó una marca cada 10 s en `ops_db.p9_marcas` y una sonda pidió `GET /health` a la URL pública cada 5 s. El desastre llegó 4 min 47 s después del inicio del último respaldo: no se alineó con él.

## 3. Tiempos medidos — RTO real

| Marca (UTC) | Evento | Tramo |
|---|---|---|
| 04:35:21 | primera petición fallida | — |
| 04:43:55 | entorno destruido · 04:43:57 inicio de `bootstrap.sh` | destrucción **8 min 34 s** |
| 04:57:01 | GKE y 3 nodos `Ready` | clúster **12 min 43 s** |
| 04:58:48 | llave en `kube-system`, ArgoCD y `sa-p9-raiz` | **1 min 42 s** |
| 05:03:17 | ola -15: **volúmenes restaurados** (Restore `sa-p9-dr-20261017-050248` desde `…043010`) | complementos + restauración **4 min 29 s** |
| 05:04:25 | **primera respuesta 200** | plataforma **1 min 08 s** |
| 05:06:08 | todas las Application `Synced/Healthy`; fin del bootstrap (22 min 11 s) | — |

**RTO medido: 29 min 04 s** (declarado 40 → **cumple**, con 11 min de margen).
La sonda registró 206 peticiones fallidas seguidas: ninguna intermitencia, una sola caída y una sola vuelta.

## 4. Pérdida medida — RPO real

- Restaurado el respaldo `sa-p9-cada-15m-20261017043010`, iniciado a las **04:30:10**.
- Marcas escritas antes del desastre: **81** · recuperadas con contenido idéntico: **57** · **perdidas: 24**, las escritas entre **04:30:34 y 04:34:47**.
- **RPO medido: 4 min 23 s** (declarado 15 → **cumple**).
- Dos marcas posteriores al inicio del respaldo (04:30:12 y 04:30:23) sí volvieron: el snapshot del disco se toma unos segundos después de que el respaldo empieza, no en el instante del inicio.
- Huella md5 tabla por tabla: idénticas `auth_db.users`, `catalog_db.*`, `order_db.*` y `notification_db.notifications`. Difieren las tablas que recibieron escrituras durante la prueba (`heartbeats`, `heartbeat_summaries`, `p9_marcas`), cuya huella previa se tomó al iniciar la prueba, 15 min antes del desastre.

**Qué no se recuperó y por qué:** lo confirmado en PostgreSQL entre el snapshot (~04:30:24) y el desastre, y los mensajes en tránsito de RabbitMQ del mismo intervalo. No es un fallo de la restauración: es la definición de un respaldo periódico.

## 5. Puntos únicos de fallo detectados

La prueba y su preparación revelaron, en este orden:

1. **Facturación:** con la cuenta cerrada, ninguna API de GKE respondía. Ningún mecanismo técnico lo cubre.
2. **DNS bajo `default-deny` (defecto latente desde la P8):** GKE resuelve vía NodeLocal DNSCache y la política solo autorizaba `kube-dns`. En kind nunca se vio porque kind no aplica NetworkPolicy. En el primer arranque real, 4 servicios cayeron con `gaierror`. Corregido (`envs/comunes.yaml`).
3. **Orden de las olas no garantizado:** una Application recién creada reporta `Healthy` antes de tener recursos, y la plataforma arrancó con la restauración aún en curso. Corregido exigiendo `Healthy` y `Synced`. En esta prueba la restauración terminó 12 s antes de la ola 0.
4. **ArgoCD podía borrar respaldos:** Velero copia a cada `Backup` la marca de seguimiento del Schedule, y ArgoCD los trataba como propios y prunables. Corregido con `resource.exclusions`.
5. **PostgreSQL y RabbitMQ con una réplica:** drenar su nodo dejó `/health` sin servicio **26 s** (93,69 % en la prueba de peor caso). En cambio, el drenaje típico tuvo 100 % de disponibilidad.
6. **Una sola zona;** la IP reservada es regional.
7. **Dependencias externas en el arranque:** GitHub, GHCR y Sigstore/Rekor.
8. **El token de Terraform:** `print-access-token` devolvió uno a punto de vencer, y el primer `apply` quedó con el estado sin subir y el candado puesto. Corregido; procedimiento en el runbook §5.

## 6. Brecha y plan

| | Declarado | Medido | Brecha |
|---|---|---|---|
| RTO | 40 min | 29 min 04 s | −10 min 56 s |
| RPO | 15 min | 4 min 23 s | −10 min 37 s |

Los dos objetivos se cumplen, pero no por igual:

- **El RTO no tiene tanto margen como parece.** El 30 % fue la destrucción: en un desastre real el clúster desaparece de golpe y se reconstruye sin esperar, así que la parte atribuible al sistema son los 22 min 11 s del bootstrap. De esos, el 57 % es GKE. Un clúster regional o un primer arranque con imágenes frías podrían comerse el margen.
- **El RPO medido es el de un instante concreto.** El peor caso sigue siendo 15 min más ~15 s de snapshot; la media esperada es ~7,5 min.

Para cerrar lo que queda, por impacto sobre costo:

1. **RPO de segundos:** archivado continuo del WAL de PostgreSQL a GCS, o CloudNativePG con Barman.
2. **Quitar el SPOF de datos:** PostgreSQL con réplica en espera y RabbitMQ en clúster de 3.
3. **RTO menor:** imágenes en Artifact Registry regional y, si se justificara, un clúster mínimo en espera.
4. **Facturación:** alertas de presupuesto y un segundo medio de pago.
