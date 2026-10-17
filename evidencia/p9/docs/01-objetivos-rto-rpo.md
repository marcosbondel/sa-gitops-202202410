# Objetivos de recuperación declarados — RTO y RPO

> **Declarados ANTES de cualquier prueba.** La fecha del commit que introdujo
> este archivo en `P9/docs/` es la prueba: es anterior a todos los registros
> de `P9/docs/evidencias/`. Los valores medidos se contrastan con estos en el
> [informe de la prueba de DR](04-informe-prueba-dr.md) y no se ajustan
> después para que «cuadren» (§1.3, honestidad técnica).

| Objetivo | Valor comprometido | Escenario que cubre |
|---|---|---|
| **RTO** — tiempo máximo sin servicio | **40 minutos** | pérdida total del clúster de GKE (plano de control, nodos, discos) |
| **RPO** — máxima pérdida de datos confirmados | **15 minutos** | ídem, y también borrado o corrupción de datos con el clúster vivo |

## Cómo se miden (definiciones operativas)

Sin una definición precisa, un RTO se puede «cumplir» eligiendo bien desde
dónde se empieza a contar. Estas son las reglas, fijadas antes de medir:

- **RTO medido** = primera respuesta `200` de `GET /health` en la URL
  **pública** después del desastre − primera respuesta fallida. Lo mide una
  sonda externa cada 5 s (`scripts/lib.sh`, `sonda_iniciar`) por el mismo
  camino que un usuario: balanceador → ingress-nginx → gateway → los 4
  servicios → PostgreSQL. Un pod `Ready` que no contesta cuenta como caída.
  Incluye el tiempo de destrucción posterior a la primera falla: en la
  prueba, la reconstrucción empieza cuando la destrucción termina.
- **RPO medido** = instante de la última escritura confirmada antes del
  desastre − instante de la última escritura que volvió tras restaurar. Lo
  mide un escritor que inserta una marca cada 10 s en `ops_db.p9_marcas`
  hasta el momento del desastre; después se cuenta qué marcas volvieron, con
  el mismo contenido (`scripts/analisis/medir.py`).
- **Contenido verificado** = para cada tabla de cada base `*_db`: número de
  filas y md5 de todas sus filas ordenadas, antes y después (`huella_bd`).

## Justificación del RTO: 40 minutos

El RTO no es un deseo: es la suma de lo que tarda cada etapa de
`scripts/bootstrap.sh` (ver el [diagrama](02-diagrama-bootstrap.md)), más un
margen para lo que la prueba descubra.

| Etapa | Estimado | De qué depende |
|---|---|---|
| Detección + inicio de la reconstrucción | 1–2 min | en la prueba, la destrucción en curso (`terraform destroy`) |
| `00-fundacion` (sin cambios: sobrevive) | ~1 min | refresco del estado remoto |
| `10-cluster`: plano de control GKE + pool de 3 nodos | 10–12 min | GCP; no se puede acelerar sin pagar un clúster en espera |
| `20-gitops`: llave de Sealed Secrets + ArgoCD | 3–4 min | descarga de imágenes de ArgoCD |
| Ola -40: Velero, Kyverno, Rollouts, ingress-nginx, Sealed Secrets | 4–6 min | imágenes; IAM propagando el vínculo de Workload Identity |
| Ola -15: restauración de los volúmenes | 2–4 min | sincronización con el bucket (30 s) + discos desde snapshot |
| Olas -10 a 0: secretos y plataforma (stage + prod) | 4–6 min | PostgreSQL arrancando sobre el volumen restaurado |
| **Total estimado** | **~25–35 min** | |
| **Comprometido (con margen)** | **40 min** | |

El componente dominante es GKE, y es un costo **asumido**: la alternativa
—un clúster de reserva siempre encendido en otra zona— bajaría el RTO a
minutos y duplicaría la factura. Para una plataforma académica sin usuarios
reales, 40 minutos de indisponibilidad no tienen consecuencias que
justifiquen ese gasto. En un sistema con usuarios, este número sería el
primero en revisarse.

## Justificación del RPO: 15 minutos

Lo fija la frecuencia del Schedule de Velero `sa-p9-cada-15m`
(`*/15 * * * *`), y la frecuencia sale de dos límites reales:

- **Por debajo, GCP:** un disco persistente admite como mucho un snapshot
  cada 10 minutos. Un calendario de 5 o 10 minutos fallaría de forma
  intermitente por límite de frecuencia, y un respaldo que falla a veces es
  peor que uno más espaciado que no falla nunca.
- **Por encima, lo que vale el dato:** la plataforma escribe sola un latido
  cada 2 minutos (`heartbeat-writer`). Con 15, el peor caso pierde ~7
  latidos, y se puede contar exactamente cuáles.

El RPO **esperado** es la mitad (~7,5 min de media), porque el desastre cae
en un instante aleatorio entre dos respaldos; 15 min es el **peor caso**
comprometido, más los segundos que tarda el snapshot en tomarse.

Bajar de 15 minutos exige otra técnica, no otro número: archivado continuo
del WAL de PostgreSQL a GCS (recuperación a un instante, RPO de segundos).
Está fuera del alcance de esta práctica y queda como plan en el informe.

## Lo que NO cubren estos objetivos

Declarado para que no se entienda que cubren más de lo que cubren:

- **Pérdida de la región `us-central1` entera:** el bucket (`US`) y los
  snapshots (`us`) sobreviven, pero la reconstrucción en otra región exige
  cambiar `REGION`/`ZONE` y la IP reservada es regional. No medido.
- **Pérdida del proyecto de GCP o de su facturación:** con la facturación
  cerrada no hay API de GKE. Es un punto único de fallo que esta práctica
  vivió de verdad (ver el informe).
- **Pérdida de GitHub:** el repositorio GitOps es la fuente de verdad de
  ArgoCD; sin él, el clúster se crea pero no se llena.
