# Preguntas teóricas — el comportamiento de ESTE sistema ante la pérdida

Respuestas sobre la implementación entregada, no definiciones generales
(criterio 1.4: «analiza el comportamiento de su propio sistema ante
escenarios de pérdida y reconoce sus límites»). Cada una cita dónde se ve en
el código o en la evidencia.

---

**1. ¿Qué se puede reconstruir automáticamente y qué se pierde de forma irreversible?**

Se reconstruye todo lo **declarativo**: el clúster (Terraform, estado en
GCS), ArgoCD y su configuración (Terraform), y todo lo que corre en el
clúster (Git, vía el app-of-apps). Se **recupera** —que no es lo mismo— lo
que tiene estado: los volúmenes de PostgreSQL y RabbitMQ (snapshots de
Velero) y la llave de los secretos (Secret Manager). Se pierde
irreversiblemente lo escrito después del último snapshot: hasta 15 min de
datos. El Job de restauración solo restaura PVC y PV, precisamente porque
todo lo demás tiene una fuente mejor que el respaldo: Git.

**2. ¿Por qué el estado de Terraform en GCS y no local? ¿Qué pasa si se pierde ese bucket?**

Con estado local, solo la máquina del autor puede reconstruir: era la
debilidad del §3.1. En GCS lo lee cualquiera con acceso al proyecto, y el
backend bloquea con un objeto `.tflock` (demostrado en
`prueba-bloqueo.sh`). Si se pierde el bucket, Terraform no sabe qué existe:
la fundación chocaría con recursos que ya están (bucket, cuentas de
servicio) y habría que importarlos. Por eso el bucket está versionado y el
runbook lo comprueba en el paso 2, **antes** de reconstruir.

**3. ¿Por qué snapshots de disco y no el respaldo por sistema de archivos (Kopia)?**

Kopia copia los archivos de una base EN MARCHA uno por uno, en instantes
distintos; el resultado puede ser un directorio que PostgreSQL no acepta. El
snapshot es consistente ante caídas: el disco entero en un instante, como
tras un corte de luz, que es de lo que PostgreSQL sabe recuperarse con su
WAL. El hook `CHECKPOINT` previo reduce lo que hay que rehacer. Y restaurar
un snapshot no necesita un pod, así que ocurre **antes** de que ArgoCD cree
PostgreSQL. El costo: el snapshot vive en Compute Engine, no en el bucket, y
depende del proveedor.

**4. ¿Qué pasaría si la plataforma se desplegara antes que la restauración?**

El StatefulSet crearía `data-sa-platform-postgresql-0` vacío, `initdb`
inicializaría una base nueva, y Velero **no** restaura encima de un PVC que
existe (`existingResourcePolicy: none`): el sistema arrancaría sano y vacío,
sin un solo error. Lo evitan las olas (-15 antes que 0) y, sobre todo, el
script de salud de `Application` en `argocd-cm`, sin el cual ArgoCD no
espera entre olas.

**5. ¿Cómo sabe el Job de restauración si es un desastre o un primer arranque?**

No se lo dice nadie: lo deduce. Espera a que el bucket esté `Available` y a
que Velero haya sincronizado al menos una vez (`lastSyncedTime`); si hay PVC,
no hace nada; si el bucket no tiene respaldos, es un primer arranque; si
tiene, restaura el último `Completed`. Y si tiene respaldos pero ninguno
`Completed`, **falla a propósito**: arrancar vacío encima de un desastre es
el error silencioso más caro posible.

**6. ¿Por qué el Schedule de Velero se aplica al final (ola 10)?**

Porque un tic del cron que cayera DURANTE la reconstrucción —antes de la
ola -15— respaldaría los namespaces vacíos, y ese respaldo sería «el más
reciente» para la siguiente recuperación: se restauraría la nada. Al final,
la plataforma ya está restaurada cuando llega el primer tic. (Se creía que
Velero respaldaba al crear el Schedule; la primera reconstrucción real mostró
que en la versión 1.18 espera al siguiente tic del cron.)

**7. ¿Qué pasa con los secretos si se destruye el clúster?**

Los 16 `SealedSecret` son criptograma en un repositorio público; solo la
llave privada los abre. En la P8 esa llave vivía solo en el clúster. Aquí la
genera Terraform en la capa que no se destruye, vive en Secret Manager y
`20-gitops` la pone en `kube-system` antes de que exista el controlador, que
la adopta en lugar de generar otra. Con la renovación automática apagada
(`keyrenewperiod: 0`), porque una llave nueva generada dentro del clúster
nunca llegaría a Secret Manager. La segunda copia está en Velero
(`sa-p9-llave`). Se demuestra con la huella SHA-256 del certificado:
igual en el clúster, en Secret Manager y en el repositorio (`verificar.sh`).

**8. ¿Por qué el servicio sigue respondiendo al drenar un nodo, y cuándo NO?**

Porque cada servicio tiene ≥ 2 réplicas en nodos distintos (anti-afinidad),
un `PodDisruptionBudget` con `minAvailable: 1` que impide que el drenaje
desaloje las dos a la vez, y el controlador de ingress tiene 2 réplicas con
anti-afinidad obligatoria y su propio PDB. NO sigue respondiendo del todo
si el nodo drenado es el de PostgreSQL: tiene una réplica, y mientras su
disco se vuelve a montar en otro nodo, `/health` falla. Está medido
(`prueba-nodo.sh --peor-caso`) y declarado como punto único de fallo.

**9. `minAvailable: 1` con 2 réplicas, ¿por qué no `maxUnavailable: 1`?**

Con 2 réplicas significan lo mismo. Difieren cuando el HPA escala: con 4
réplicas, `minAvailable: 1` dejaría desalojar 3 a la vez; `maxUnavailable: 1`
solo 1. Para el gateway de producción (HPA 3–6) `maxUnavailable` sería más
conservador; se mantuvo `minAvailable` por continuidad con la P8 y porque el
drenaje de un nodo con anti-afinidad nunca saca más de una réplica por
servicio.

**10. ¿Qué pasa si GitHub no está disponible durante la recuperación?**

El clúster se crea y ArgoCD se instala (Terraform no depende de GitHub),
pero la raíz no puede leer `apps/` y nada más se despliega. Es una
dependencia externa declarada. La mitigación sería un espejo del
repositorio GitOps en Cloud Source Repositories o en el propio GCS.

**11. ¿Qué cambiaría para bajar el RPO a segundos?**

No basta con respaldar más seguido: GCP no deja snapshotear un disco más de
una vez cada 10 minutos. Hace falta otra técnica: archivado continuo del WAL
de PostgreSQL a GCS (o CloudNativePG con Barman), que permite recuperar a
cualquier instante. Velero seguiría respaldando lo demás.

**12. ¿Qué es lo que más tiempo cuesta en la recuperación y se puede reducir?**

La creación del clúster de GKE (~10–12 min) y la descarga de imágenes. Lo
primero solo se elimina pagando un clúster en espera; lo segundo, con
imágenes en Artifact Registry de la misma región. Ver la tabla de tiempos del
informe.

**13. ¿Por qué el TTL de los respaldos es de 30 días y no de 3?**

Porque Velero borra los respaldos vencidos en cuanto los descubre. En un
clúster reconstruido tras un apagón más largo que el TTL, la sincronización
con el bucket los encontraría vencidos y los borraría casi a la vez que el
Job intenta usarlos. La regla de GCS es más larga (45 días) para que Velero
—que sabe qué borra, incluidos los snapshots— borre primero.

**14. ¿Qué pasa si se cae un nodo en mitad de un canary?**

El Rollout no pierde su estado (vive en el objeto `Rollout`, no en el
pod); el controlador de Argo Rollouts tiene 2 réplicas con elección de
líder; las réplicas canary y estables desalojadas se recrean respetando
los PDB. Si la prueba de análisis falla por el drenaje, el canary revierte:
falla cerrado, como en la P8.
