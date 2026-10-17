# Runbook de recuperación — plataforma `sa-platform` en GKE

**Para quién:** cualquier persona con acceso al proyecto de GCP, aunque no
conozca el sistema y no pueda hablar con su autor.
**Qué resuelve:** la pérdida total del clúster (§3), la pérdida o corrupción
de datos con el clúster vivo (§7), la caída de un nodo (§6) y la pérdida de
la llave de los secretos (§8).
**Cuánto tarda:** reconstrucción total ≈ 30–40 min, casi todo esperando a
GCP. Restauración de datos en caliente ≈ 5–10 min.

> Cada paso tiene un **✔ Verificación** con el resultado esperado. Si lo que
> ves no coincide, **no sigas**: ve a la tabla de fallos del paso (§5).

---

## 0. Antes de empezar: ¿cuál es tu escenario?

| Síntoma | Escenario | Ve a |
|---|---|---|
| `kubectl` no conecta y la consola de GCP no muestra el clúster `sa-p9`, o el clúster existe pero está irrecuperable | **Pérdida total del clúster** | §1 → §2 → §3 → §4 |
| El sistema responde, pero faltan datos o están corruptos (un `DELETE` equivocado, una migración rota) | **Restauración de datos** | §1 → §7 |
| Un nodo cayó o hay que drenarlo | **Pérdida de nodo**: no hay que hacer nada | §6 |
| ArgoCD muestra los `SealedSecret` con error «no key could decrypt secret» | **Llave de secretos** | §8 |
| `gcloud` responde «billing is disabled» / «requires billing to be enabled» | **Facturación** | §0.1 |

### 0.1 Si la facturación está cerrada

Nada de lo que sigue funciona sin facturación: GKE no tiene API.

```bash
gcloud billing projects describe sociedadanonima-507519 --format='value(billingEnabled)'
```

✔ **Verificación:** imprime `True`. Si imprime `False`, un administrador de
facturación debe vincular una cuenta de facturación abierta en
<https://console.cloud.google.com/billing/linkedaccount?project=sociedadanonima-507519>.
Ese paso no tiene alternativa por línea de comandos sin facturación.

---

## 1. Preparar la máquina (una vez, ~10 min)

### 1.1 Herramientas

macOS con Homebrew (en Linux: los mismos paquetes con el gestor de la
distribución):

```bash
brew install --cask google-cloud-sdk
brew install hashicorp/tap/terraform kubectl helm@3 velero jq kubeseal argocd
gcloud components install gke-gcloud-auth-plugin --quiet
```

✔ **Verificación:**

```bash
terraform version | head -1     # Terraform v1.16.x
kubectl version --client        # cualquier v1.3x
helm version --short            # v3.x  (no v4: los scripts anteponen helm@3)
velero version --client-only    # v1.18.x
```

### 1.2 Accesos

Necesitas, en el proyecto `sociedadanonima-507519`:

- rol **Owner** (o **Editor** + **Secret Manager Secret Accessor** +
  **Kubernetes Engine Admin**);
- nada en GitHub: el repositorio GitOps es público y ArgoCD lo lee sin
  credenciales.

```bash
gcloud auth login <tu-cuenta>
gcloud auth application-default login     # opcional; los scripts pasan su propio token
```

### 1.3 El código

```bash
git clone git@github.com:marcosbondel/Practicas-SA-B-202202410.git
cd Practicas-SA-B-202202410
```

### 1.4 Tu cuenta y tu proyecto

Los scripts **no** usan la configuración activa de gcloud (puede apuntar a
otro proyecto). Usan estas dos variables; los valores por defecto son los del
autor:

```bash
export CUENTA=<tu-cuenta@dominio>          # por defecto <cuenta-del-operador>
export PROJECT_ID=sociedadanonima-507519   # por defecto, este
```

✔ **Verificación:** el encabezado que imprime cualquier script muestra tu
cuenta y el proyecto correcto:

```
  cuenta   <tu-cuenta>
  proyecto sociedadanonima-507519 · zona us-central1-a · clúster sa-p9 (3 × e2-standard-4)
```

---

## 2. Comprobar qué sobrevivió (2 min)

La recuperación depende de cuatro cosas que viven **fuera** del clúster. Si
alguna falta, la reconstrucción no podrá recuperar los datos o los secretos:
compruébalo **antes** de reconstruir.

```bash
gcloud storage ls gs://sociedadanonima-507519-sa-p9-tfstate/          # 1. estado de Terraform
gcloud storage ls gs://sociedadanonima-507519-sa-p9-respaldos/backups/ | tail -3   # 2. respaldos
gcloud secrets versions list sa-p9-sealed-secrets-llave                 # 3. llave de los secretos
gcloud compute addresses describe sa-p9-ingress --region us-central1 --format='value(address,status)'  # 4. IP
```

✔ **Verificación:**

1. aparecen `fundacion/`, `cluster/` y `gitops/`;
2. aparecen carpetas `sa-p9-cada-15m-<fecha>/`; la última, de hace pocos minutos u horas;
3. hay al menos una versión `enabled`;
4. una IP y `RESERVED` (o `IN_USE` si quedó una regla huérfana: el bootstrap la libera).

| Si falta… | Consecuencia | Qué hacer |
|---|---|---|
| 1 (estado) | Terraform no sabe qué existe | `bootstrap.sh` lo recrea vacío; la fundación chocará con recursos existentes → importarlos (`terraform import`) antes de seguir |
| 2 (respaldos) | la plataforma arrancará **vacía** | continuar; los datos no son recuperables por esta vía. Anotarlo en el informe del incidente |
| 3 (llave) | los secretos del repositorio no se abren | §8 antes de seguir |
| 4 (IP) | cambia la URL pública | `bootstrap.sh` la recrea; volver a ejecutar `configurar-gitops.sh --solo-ip` y llevar el cambio a `main` |

---

## 3. Reconstruir (≈ 30–40 min, sin intervención)

### 3.1 Si queda algo del clúster viejo

Si el clúster existe pero está roto (no es el caso de un desastre total),
destrúyelo primero de forma controlada. **Borra los discos de los
volúmenes**: los datos se recuperarán del respaldo.

```bash
P9/scripts/desastre.sh --confirmar sa-p9
```

✔ **Verificación:** la última línea dice `entorno destruido: no hay clúster,
ni discos de datos; la fundación sigue en pie`, y

```bash
gcloud container clusters list --filter=name=sa-p9      # (vacío)
```

### 3.2 El comando

```bash
P9/scripts/bootstrap.sh
```

Es **el único comando**. No pregunta nada; no hay que esperar a nada para
lanzarlo de nuevo si se interrumpe: cada etapa es idempotente.

Todo lo que hace queda en `P9/docs/evidencias/reconstruccion-<UTC>.log`, con
la hora de cada paso. Guarda ese archivo: es la evidencia del incidente.

### 3.3 Qué vas a ver, en orden, y cómo saber que va bien

El script escribe una línea por evento: `<UTC>  +mm:ss  [etapa]  mensaje`.
Estas son las etapas en el orden en que aparecen, con su duración normal:

| # | Etapa en el registro | Duración normal | ✔ Va bien si… |
|---|---|---|---|
| 1 | `[estado]` | < 1 min | `facturación habilitada` y el bucket de estado `ya existe` |
| 2 | `[fundacion]` | ~1 min | `✓ terraform apply 00-fundacion` con `No changes` (la fundación sobrevive al desastre) |
| 3 | `[ip]` | < 1 min | `IP pública reservada: <ip>`; si hubo una regla huérfana, `…: se borra` |
| 4 | `[cluster]` | 10–12 min | `✓ terraform apply 10-cluster` y `nodos: gke-sa-p9-…-xxxx Ready,…` (tres) |
| 5 | `[gitops]` | ~3 min | `✓ terraform apply 20-gitops` |
| 6 | `[argocd]` | 10–15 min | una línea por cambio de estado de cada Application; las olas avanzan en orden: primero `sa-p9-velero`, `sa-p9-kyverno`… luego `sa-p9-namespaces`, `sa-p8-politicas`, **`sa-p9-restauracion`**, los secretos y al final `sa-p8-plataforma-*` y `sa-p9-respaldos` |
| 7 | `[datos]` | — | `restauración: Restaurado — volúmenes restaurados desde sa-p9-cada-15m-<fecha>` |
| 8 | `[servicio]` | < 1 min | `http://sa-p9.<ip>.nip.io/health → 200` |
| 9 | `[fin]` | — | `sistema reconstruido y respondiendo en NN min SS s` |

Mientras corre la etapa 6 puedes mirar en otra terminal:

```bash
kubectl -n argocd get applications -w
kubectl -n velero logs job/sa-p9-restauracion -f      # durante la ola -15
```

### 3.4 El dato que hay que mirar dos veces: la restauración

La línea `[datos]` dice de qué respaldo salieron los volúmenes y cuándo
empezó ese respaldo. **Ese instante es el punto al que volvieron los datos**:
todo lo escrito después se perdió (es el RPO del incidente).

```bash
kubectl -n velero get configmap sa-p9-restauracion-resultado -o yaml
```

| `estado` | Significado | Acción |
|---|---|---|
| `Restaurado` | los volúmenes vienen del respaldo indicado | ninguna |
| `PrimerArranque` | el bucket no tenía respaldos: la plataforma nació vacía | correcto solo si es la primera vez que se levanta el sistema; si no, ver §2 punto 2 |
| `Omitido` | ya había volúmenes (el Job se repitió sobre un clúster vivo) | ninguna |
| `Fallido` | el Job se detuvo **a propósito** para no arrancar vacío encima de un desastre | §5, fila «restauración» |

---

## 4. Verificar (3 min)

```bash
P9/scripts/verificar.sh
```

✔ **Verificación:** termina con `RESULTADO: todo verificado ✓`. Comprueba,
y muestra el dato de cada cosa:

- la raíz `sa-p9-raiz` y **todas** las Application `Synced/Healthy`;
- la huella SHA-256 del certificado de Sealed Secrets es **la misma** en el
  clúster, en Secret Manager y en el repositorio; los 16 `SealedSecret` están
  descifrados y sus `Secret` existen;
- el destino de Velero está `Available`, los Schedules existen y hay un
  respaldo `Completed` de hace menos de 20 min (el Schedule toma uno al
  crearse);
- las 4 `ClusterPolicy` de Kyverno están `Ready` y **un pod con `:latest`
  es rechazado**; los Rollouts están `Healthy` (flujo de la P8 intacto);
- `GET /health` responde `200` por la IP pública y `ops_db.heartbeats` tiene
  datos anteriores al desastre.

Comprobación a mano del contenido (opcional):

```bash
kubectl -n sa-p8-prod exec sa-platform-postgresql-0 -c postgresql -- bash -c \
  'PGPASSWORD=$(cat $POSTGRES_PASSWORD_FILE) psql -h 127.0.0.1 -U postgres -d ops_db -c \
   "select count(*), max(executed_at) from heartbeats"'
```

✔ el `max(executed_at)` es anterior al desastre y cercano al inicio del
respaldo restaurado; luego vuelve a crecer cada 2 minutos.

Interfaz de ArgoCD (no está expuesta a Internet a propósito):

```bash
kubectl -n argocd port-forward svc/argocd-server 8080:80
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d; echo
# http://localhost:8080 · usuario admin
```

---

## 5. Si algo falla

| Etapa | Síntoma | Causa probable | Qué hacer |
|---|---|---|---|
| estado | `no tiene facturación habilitada` | facturación cerrada | §0.1 |
| estado | `la cuenta … no está autenticada` | falta `gcloud auth login` | `gcloud auth login $CUENTA` y repetir |
| fundacion | `Error acquiring the state lock` | otra persona (u otra terminal) está aplicando | esperar; si nadie está aplicando y el candado quedó de una ejecución muerta: `terraform -chdir=P9/terraform/00-fundacion force-unlock -force <ID>`. En GCS el ID es un **número**: la generación del objeto del candado, `gcloud storage objects describe gs://sociedadanonima-507519-sa-p9-tfstate/fundacion/default.tflock --format='value(generation)'` (el campo `ID` del JSON no sirve). Si además el error dice «Failed to persist state», Terraform dejó `errored.tfstate` en el directorio: `terraform state push errored.tfstate` y borrarlo (contiene la llave) |
| fundacion | `aún no tiene la IP reservada` | primera vez en un proyecto nuevo | `P9/scripts/configurar-gitops.sh`, llevar el cambio a `main` del repositorio GitOps, repetir |
| cluster | `Quota exceeded` / `ZONE_RESOURCE_POOL_EXHAUSTED` | cuota o capacidad de la zona | `ZONE=us-central1-b P9/scripts/bootstrap.sh` (la IP es regional: sirve) |
| argocd | una Application se queda en `Progressing` > 10 min | imagen que no baja, pod que no arranca | `kubectl -n argocd get application <app> -o yaml \| grep -A20 'status:'`; luego `kubectl get pods -A \| grep -v Running` |
| argocd | `sa-p9-velero` en `Progressing` con «Validando el acceso al bucket» > 5 min | IAM aún propaga el vínculo de Workload Identity, o falta | esperar 5 min más; si sigue: `kubectl -n velero logs deploy/velero \| grep -i denied`, y volver a ejecutar `P9/scripts/bootstrap.sh` (reaplica el vínculo) |
| argocd | `sa-p9-kyverno` `OutOfSync` con «Too long» | aplicado sin Server-Side Apply | ya está en la Application (`ServerSideApply=true`); forzar: `argocd app sync sa-p9-kyverno --server-side` |
| restauración | Job `sa-p9-restauracion` en `Error`, ConfigMap `Fallido: hay N respaldos pero ninguno Completed` | los respaldos están `PartiallyFailed` | `velero backup describe <nombre> --details`; si los volúmenes están, forzar ese respaldo: §9 |
| restauración | `Fallido: el bucket no estuvo accesible` | igual que la fila de Velero | idem; después borrar el Job para que ArgoCD lo repita: `kubectl -n velero delete job sa-p9-restauracion` |
| servicio | `ingress-nginx-controller` con `EXTERNAL-IP <pending>` | la IP sigue retenida por una regla huérfana | `gcloud compute forwarding-rules list --filter="IPAddress=<ip>"` y borrarla; el bootstrap lo hace solo **si no hay clúster**, así que con clúster vivo hay que hacerlo a mano |
| servicio | pods en `CreateContainerConfigError` | algún `Secret` no se descifró | §8 |
| servicio | pods de la plataforma rechazados por Kyverno («signature») | Rekor/Sigstore inaccesible desde el clúster | esperar y reintentar; es dependencia externa declarada |

Tras corregir, **vuelve a ejecutar `P9/scripts/bootstrap.sh`**: retoma desde
donde se quedó.

---

## 6. Pérdida de un nodo — no hay que hacer nada

El sistema lo absorbe: 3 nodos, réplicas en nodos distintos
(anti-afinidad), `PodDisruptionBudget` en cada servicio y en el controlador
de ingress. Si un nodo cae o hay que drenarlo:

```bash
kubectl drain <nodo> --ignore-daemonsets --delete-emptydir-data   # si es mantenimiento
kubectl get pods -n sa-p8-prod -o wide                            # los pods se reubican
kubectl uncordon <nodo>                                           # al terminar
```

✔ **Verificación:** `curl -s -o /dev/null -w '%{http_code}' http://sa-p9.<ip>.nip.io/health/ready`
sigue devolviendo `200` durante todo el drenaje.

**Excepción declarada:** PostgreSQL y RabbitMQ tienen **una** réplica. Si
cae su nodo, la base deja de responder mientras GKE vuelve a montar su disco
en otro nodo: **26 s** medidos (`/health` al 93,69 % durante el drenaje,
`evidencias/prueba-nodo-peor-caso-20261017T040256Z.log`). Se recupera solo.

---

## 7. Restaurar datos con el clúster vivo (≈ 5–10 min)

Para un borrado o una corrupción de datos. **Pierde lo escrito después del
respaldo elegido**: elige el respaldo con cuidado.

### 7.1 Elegir el respaldo

```bash
velero backup get --selector velero.io/schedule-name=sa-p9-cada-15m | head
```

Elige el último `Completed` **anterior** al momento del daño:

```bash
export RESPALDO=sa-p9-cada-15m-<AAAAMMDDhhmmss>
velero backup describe $RESPALDO --details | grep -A6 'Volume Snapshots'
```

✔ el respaldo lista los snapshots de `data-sa-platform-postgresql-0`.

### 7.2 Pausar ArgoCD (si no, deshace los pasos siguientes)

```bash
kubectl -n argocd patch application sa-p9-raiz --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
kubectl -n argocd patch application sa-p8-plataforma-prod --type merge -p '{"spec":{"syncPolicy":{"automated":null}}}'
```

✔ `kubectl -n argocd get application sa-p9-raiz -o jsonpath='{.spec.syncPolicy}'` no muestra `automated`.

### 7.3 Bajar PostgreSQL y retirar su volumen dañado

```bash
kubectl -n sa-p8-prod scale statefulset sa-platform-postgresql --replicas=0
kubectl -n sa-p8-prod wait --for=delete pod/sa-platform-postgresql-0 --timeout=180s
kubectl -n sa-p8-prod delete pvc data-sa-platform-postgresql-0
```

✔ `kubectl -n sa-p8-prod get pvc` ya no lista `data-sa-platform-postgresql-0`.

### 7.4 Restaurar el volumen desde el snapshot

```bash
velero restore create restauracion-$(date -u +%Y%m%d-%H%M%S) \
  --from-backup $RESPALDO \
  --include-namespaces sa-p8-prod \
  --include-resources persistentvolumeclaims,persistentvolumes \
  --restore-volumes=true --wait
```

✔ termina en `Completed` (un aviso «already exists» del PVC de RabbitMQ es
normal: no se toca lo que existe), y `kubectl -n sa-p8-prod get pvc` vuelve a
listar `data-sa-platform-postgresql-0` en `Bound`.

### 7.5 Subir PostgreSQL y reanudar ArgoCD

```bash
kubectl -n sa-p8-prod scale statefulset sa-platform-postgresql --replicas=1
kubectl -n sa-p8-prod wait --for=condition=Ready pod/sa-platform-postgresql-0 --timeout=600s
kubectl -n argocd patch application sa-p9-raiz --type merge \
  -p '{"spec":{"syncPolicy":{"automated":{"prune":true,"selfHeal":true}}}}'
```

✔ en ~1 min, `kubectl -n argocd get applications` vuelve a mostrar todo
`Synced/Healthy` (la raíz devuelve a la plataforma su política desde Git), y
los datos anteriores al respaldo están de vuelta (consulta de §4).

Todo este procedimiento, con medición del contenido antes y después, es
`P9/scripts/prueba-restauracion.sh`.

---

## 8. Si la llave de los secretos no está o no coincide

Síntoma: `kubectl get sealedsecrets -A` con `no key could decrypt secret`.

### 8.1 Comprobar

```bash
kubeseal --fetch-cert | openssl x509 -noout -fingerprint -sha256
gcloud secrets versions access latest --secret sa-p9-sealed-secrets-llave \
  | jq -r '."tls.crt"' | openssl x509 -noout -fingerprint -sha256
```

✔ las dos huellas son iguales. Si no lo son, el controlador está usando otra
llave: reinstalar la de Secret Manager:

```bash
bash -c 'source P9/scripts/config.sh && source P9/scripts/lib.sh && renovar_token &&
  tf_init "$TF_GITOPS" "$PREFIJO_GITOPS" &&
  terraform -chdir="$TF_GITOPS" apply -auto-approve \
    -replace=kubernetes_secret_v1.llave_sealed_secrets "${tf_vars_gitops[@]}"'
kubectl -n kube-system delete pod -l app.kubernetes.io/name=sealed-secrets
```

(Con `bash -c` porque los scripts son de Bash y la terminal de macOS es zsh.)

### 8.2 Si Secret Manager perdió la llave: la segunda copia, en Velero

El Schedule `sa-p9-llave` guarda una copia del Secret de la llave en
el bucket de respaldos.

```bash
velero backup get --selector velero.io/schedule-name=sa-p9-llave
velero restore create llave-$(date -u +%Y%m%d%H%M) \
  --from-backup <el-último> --include-namespaces kube-system --include-resources secrets --wait
kubectl -n kube-system delete pod -l app.kubernetes.io/name=sealed-secrets
```

Y devolverla a Secret Manager para que la próxima reconstrucción la use:

```bash
kubectl -n kube-system get secret sealed-secrets-llave-p9 -o json \
  | jq '{"tls.crt": (.data."tls.crt"|@base64d), "tls.key": (.data."tls.key"|@base64d)}' \
  | gcloud secrets versions add sa-p9-sealed-secrets-llave --data-file=-
```

✔ las huellas de §8.1 vuelven a coincidir y `P9/scripts/verificar.sh` da ✓
en «Continuidad de los secretos».

---

## 9. Restaurar un punto anterior al más reciente

El Job de restauración del arranque elige el respaldo `Completed` más
reciente. Para forzar otro (porque el más reciente ya contiene el daño):
editar en el repositorio GitOps `respaldos/restauracion/job.yaml`, variable
`RESPALDO`, poner el nombre elegido y llevar el cambio a `main` **antes** de
ejecutar `bootstrap.sh`. Después, volver a dejarla vacía.

---

## 10. Después del incidente

1. Guardar `P9/docs/evidencias/reconstruccion-<UTC>.log` (y el de
   `desastre-…` si se usó).
2. Anotar: hora del incidente, respaldo restaurado (§3.4), RTO del registro
   (línea `[fin]`), datos perdidos (escrituras posteriores al respaldo).
3. Si el clúster se levantó solo para recuperar y no debe quedar encendido
   (costo): `P9/scripts/desastre.sh --confirmar sa-p9` lo apaga **sin**
   tocar respaldos, llave ni IP. Los datos escritos desde el último respaldo
   se perderían: esperar antes a que el Schedule complete uno
   (`velero backup get | head -3`).
