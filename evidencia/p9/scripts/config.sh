#!/usr/bin/env bash
# Se carga con `source`: las variables se usan en los scripts que la cargan.
# shellcheck disable=SC2034
# ===========================================================================
# config.sh — Parámetros compartidos por los scripts de la Práctica 9.
#
# No se ejecuta: se carga con `source`. Todo se puede sobrescribir desde el
# entorno. Hermano de `P6/scripts/config.sh` (que ya hablaba con GKE) y de
# `P8/scripts/config.sh` (que hablaba con kind).
#
# ## Qué cambia respecto a la Práctica 8
#
# La P8 corría sobre `kind`: un clúster de un nodo dentro de Docker, en la
# laptop. Esa decisión hacía imposibles tres de los seis criterios de
# conocimiento de esta práctica, y no por configuración sino por física:
#
#   · «respaldos con almacenamiento FUERA del clúster» — no hay un fuera
#   · «el servicio responde durante el drenaje de un nodo» — hay un solo nodo
#   · «estado de Terraform en backend remoto con bloqueo» — no hay remoto
#
# Así que la P9 vive en GKE. El cambio no es un `kube_context` distinto, como
# prometía el comentario optimista de `P8/scripts/00-crear-cluster.sh`: hay
# nueve puntos de acoplamiento a kind en la P8 —hostPorts del Ingress,
# `nodeSelector: ingress-ready`, tolerancias de control-plane,
# `publish-status-address=localhost`, metrics-server instalado a mano,
# `*.local` en `/etc/hosts`, Kyverno con una réplica, `kind load` para las
# imágenes y el dimensionado de las cuotas— y cada uno está resuelto y
# anotado en las Application de `apps/` del repositorio GitOps.
#
# ## Qué NO cambia, y es a propósito
#
# Las imágenes siguen en GHCR y siguen siendo públicas, así que el kubelet de
# GKE las baja sin credenciales y Kyverno sigue verificando su firma de Cosign
# contra Rekor. No hay migración a Artifact Registry: habría obligado a
# reconstruir y volver a firmar las seis imágenes, y la cadena de suministro
# de la P8 —que ya está calificada— habría dejado de ser la misma.
# ===========================================================================

# --- Proyecto y cuenta -----------------------------------------------------
# EXPLÍCITOS, y no «lo que gcloud tenga activo». Esta máquina tiene tres
# cuentas autenticadas y varias configuraciones de gcloud; la activa apunta a
# otro proyecto de otra cuenta. Un script que tomara `gcloud config get-value
# project` crearía un clúster facturable en el lugar equivocado sin fallar.
#
# Un tercero que ejecute el runbook en su propio proyecto los sobrescribe:
#     PROJECT_ID=mi-proyecto CUENTA=yo@ejemplo.com P9/scripts/bootstrap.sh
PROJECT_ID="${PROJECT_ID:-sociedadanonima-507519}"
CUENTA="${CUENTA:-<cuenta-del-operador>}"

# Todo `gcloud` que corra a partir de aquí —también el que invoca
# `gke-gcloud-auth-plugin` para `kubectl`— usa esta cuenta y este proyecto,
# sin tocar la configuración global de la máquina.
export CLOUDSDK_CORE_ACCOUNT="$CUENTA"
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"

# --- Ubicación ------------------------------------------------------------
# Zonal y no regional, igual que en la P6: un clúster regional replica el
# plano de control en tres zonas y multiplica los nodos por tres. Para esta
# práctica es gasto sin contrapartida, y el nivel gratuito de GKE cubre la
# gestión de UN clúster zonal.
#
# Tiene una consecuencia que conviene decir, porque es un punto único de
# fallo y el §4.2 del enunciado pide enumerarlos: una zona de GCP entera
# caída se lleva este clúster. La respuesta correcta sería un clúster
# regional, y el precio de esa respuesta es triplicar los nodos.
REGION="${REGION:-us-central1}"
ZONE="${ZONE:-us-central1-a}"

# --- Nombres --------------------------------------------------------------
CLUSTER="${CLUSTER:-sa-p9}"

# Los dos ambientes de la plataforma. Mismos nombres que en la P8 para que los
# manifiestos del repositorio GitOps no tengan que cambiar de namespace.
NS_STAGE="${NS_STAGE:-sa-p8-stage}"
NS_PROD="${NS_PROD:-sa-p8-prod}"

NS_ARGOCD="${NS_ARGOCD:-argocd}"
NS_VELERO="${NS_VELERO:-velero}"

# --- Buckets de GCS -------------------------------------------------------
# Dos buckets, y la separación no es estética.
#
#   · el del ESTADO lo escribe Terraform en cada `apply`; perderlo significa
#     perder el mapa de lo que existe.
#   · el de los RESPALDOS lo escribe Velero; perderlo significa perder los
#     datos.
#
# Si compartieran bucket, una política de retención pensada para los
# respaldos —borrar lo que tiene más de N días— borraría también el estado.
#
# El prefijo del proyecto va en el nombre porque los nombres de bucket son
# globales en todo GCS: `sa-p9-tfstate` ya lo tiene alguien.
BUCKET_TFSTATE="${BUCKET_TFSTATE:-${PROJECT_ID}-sa-p9-tfstate}"
BUCKET_VELERO="${BUCKET_VELERO:-${PROJECT_ID}-sa-p9-respaldos}"

# Prefijos dentro del bucket de estado: una capa, un prefijo, un candado.
PREFIJO_FUNDACION="fundacion"
PREFIJO_CLUSTER="cluster"
PREFIJO_GITOPS="gitops"

# --- Continuidad de los secretos ------------------------------------------
# El secreto de Secret Manager con la llave de Sealed Secrets. La genera
# Terraform en la fundación (`00-fundacion/secretos.tf`) y `20-gitops` la
# instala en el clúster antes que el controlador.
SECRETO_LLAVE="${SECRETO_LLAVE:-sa-p9-sealed-secrets-llave}"

# --- Respaldos ------------------------------------------------------------
SCHEDULE_VELERO="sa-p9-cada-15m"
CM_RESULTADO_RESTAURACION="sa-p9-restauracion-resultado"

# --- Nodos ----------------------------------------------------------------
# e2-standard-4: 4 vCPU dedicados y 16 GB, tres veces.
#
# El número sale de una cuenta, no de una preferencia, y la cuenta tiene que
# sobrevivir al drenaje de un nodo —que es el §3.2, «resiliencia ante pérdida
# de nodo»—. Lo que hay que caber:
#
#   kube-system de GKE (3 nodos)                            ~1.5 CPU
#   ArgoCD, Argo Rollouts, Sealed Secrets, ingress-nginx     ~0.9 CPU
#   Kyverno con 3 réplicas de admisión                      ~0.5 CPU
#   Velero (servidor; sin node-agent: snapshots de disco)    ~0.1 CPU
#   la plataforma en los dos ambientes, en reposo           ~3.5 CPU
#                                                           ─────────
#                                                            ~6.5 CPU
#
# Tres e2-standard-4 dan ~11.7 CPU asignables (3.92 por nodo; la ficha dice 4,
# GKE se queda con el resto). Con un nodo drenado quedan ~7.8, que sigue
# cubriendo los 6.5 con margen. Ese margen es el entregable: si no cupiera, el
# drenaje dejaría pods en Pending y el criterio 2.5 se pierde entero.
#
# Por qué NO e2-standard-2, que cuesta la mitad: dan 1.93 CPU asignables por
# nodo —no 2, y la diferencia importa—, o sea 5.8 en total. Los 6.5 no caben
# ni con los tres nodos sanos. La P6 ya documentó la versión fuerte de este
# error con `e2-medium`, que declara 940m donde su ficha dice 2 vCPU.
MACHINE_TYPE="${MACHINE_TYPE:-e2-standard-4}"
NUM_NODES="${NUM_NODES:-3}"

# Disco del NODO, no de los PVC. Las seis imágenes suman menos de 700 MB; 32 GB
# estándar sobran y cuestan la cuarta parte que los 100 GB balanceados del
# defecto. Los PVC de PostgreSQL y RabbitMQ usan la StorageClass del clúster
# (`standard-rwo`, que es pd-balanced por CSI) y no se ven afectados.
DISK_TYPE="${DISK_TYPE:-pd-standard}"
DISK_SIZE="${DISK_SIZE:-32}"

# Desde 2026 un clúster nuevo no puede quedarse fuera de un canal de
# versiones: `--no-enable-autoupgrade` devuelve un 400. `stable` es el más
# conservador. Ver la nota de `P6/scripts/00-crear-cluster.sh` sobre la
# exclusión de mantenimiento, que es el sustituto y que aquí importa más que
# en la P6: una actualización automática de nodos en mitad de la prueba de DR
# falsearía el RTO medido.
RELEASE_CHANNEL="${RELEASE_CHANNEL:-stable}"

# --- Repositorio GitOps ---------------------------------------------------
# El mismo de la P8, público y separado del repositorio de código. El §3.2
# pide «conservación del flujo de la Práctica 8», y cambiar de repositorio
# habría obligado a reescribir las 7 Applications.
GITOPS_URL="${GITOPS_URL:-https://github.com/marcosbondel/sa-gitops-202202410.git}"
GITOPS_RAMA="${GITOPS_RAMA:-main}"
GITOPS_DIR="${GITOPS_DIR:-${HOME}/Documents/tech/sa-gitops-202202410}"

# --- Rutas ----------------------------------------------------------------
P9_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RAIZ="$(cd "${P9_DIR}/.." && pwd)"

TF_FUNDACION="${P9_DIR}/terraform/00-fundacion"
TF_CLUSTER="${P9_DIR}/terraform/10-cluster"
TF_GITOPS="${P9_DIR}/terraform/20-gitops"
EVIDENCIAS="${EVIDENCIAS:-${P9_DIR}/docs/evidencias}"

# El contexto que deja `gcloud container clusters get-credentials`. Su forma
# está fijada por gcloud y no se puede elegir; se construye aquí para que
# ningún script tenga que adivinarla.
KUBE_CONTEXT="${KUBE_CONTEXT:-gke_${PROJECT_ID}_${ZONE}_${CLUSTER}}"

# --- Helm 3 ---------------------------------------------------------------
# El `helm` del PATH de esta máquina es Helm 4 (v4.2.4); el chart de la
# plataforma se desarrolló y se probó con Helm 3. Igual que en las P6, P7 y P8.
if [[ -d /opt/homebrew/opt/helm@3/bin ]]; then
  export PATH="/opt/homebrew/opt/helm@3/bin:${PATH}"
fi

# --- gke-gcloud-auth-plugin -----------------------------------------------
# El plugin con el que `kubectl` se autentica contra GKE. Sin él no hay forma
# de hablar con el clúster, y el fallo aparece al final de todo el arranque
# —con el clúster ya creado y facturando— en forma de:
#
#     error: The gke-gcloud-auth-plugin binary was not found or is not
#     executable. ...
#
# El detalle que cuesta encontrar: cuando gcloud se instala con el cask de
# Homebrew, `gcloud components install gke-gcloud-auth-plugin` responde «All
# components are up to date» y el binario SÍ está instalado —en
# `share/google-cloud-sdk/bin/`— pero el cask no lo enlaza a `bin/`. Así que
# `command -v` no lo encuentra, el mensaje de gcloud dice que todo está bien,
# y la instrucción que todo el mundo repite («corre components install») no
# cambia nada.
#
# Se resuelve añadiendo el directorio del SDK al PATH, que es menos invasivo
# que crear un enlace en `/opt/homebrew/bin` —el tercero que ejecuta el
# runbook puede no tener permiso de escritura ahí—.
for _sdk in /opt/homebrew/share/google-cloud-sdk/bin \
            "${HOME}/google-cloud-sdk/bin" \
            /usr/local/share/google-cloud-sdk/bin; do
  if [[ -x "${_sdk}/gke-gcloud-auth-plugin" ]]; then
    export PATH="${_sdk}:${PATH}"
    break
  fi
done
unset _sdk

# Lo exige el plugin desde la versión 1.26 de Kubernetes. Sin esta variable,
# `kubectl` usa el proveedor de autenticación antiguo, que fue eliminado.
export USE_GKE_GCLOUD_AUTH_PLUGIN=True

# --- Comprobaciones -------------------------------------------------------
# Se hacen aquí y no en cada script porque el runbook (§4) tiene que poder
# ejecutarlo un tercero que no conoce el sistema: es mejor que falle en la
# primera línea con el `brew install` que le falta, que a los ocho minutos con
# el clúster a medio crear.
faltan=()
for cmd in gcloud kubectl helm terraform velero jq kubeseal openssl curl; do
  command -v "$cmd" >/dev/null || faltan+=("$cmd")
done
if (( ${#faltan[@]} )); then
  echo "ERROR: faltan en el PATH: ${faltan[*]}" >&2
  echo "  brew install kubectl helm@3 hashicorp/tap/terraform velero jq kubeseal openssl" >&2
  echo "  curl https://sdk.cloud.google.com | bash   # gcloud" >&2
  exit 1
fi

helm version --short | grep -q '^v3\.' || {
  echo "ERROR: se necesita Helm 3, encontrado: $(helm version --short)" >&2
  echo "  brew install helm@3   (los scripts antepondrán /opt/homebrew/opt/helm@3/bin)" >&2
  exit 1
}

# `gke-gcloud-auth-plugin` no es opcional: sin él `kubectl` no puede
# autenticarse contra GKE, y el fallo aparece al final de todo el proceso —con
# el clúster ya creado y facturando— en forma de un error de credenciales que
# no menciona el plugin.
command -v gke-gcloud-auth-plugin >/dev/null || {
  echo "ERROR: falta 'gke-gcloud-auth-plugin' y no está en los sitios conocidos." >&2
  echo "  gcloud components install gke-gcloud-auth-plugin --quiet" >&2
  echo "  ...y si eso dice «up to date», el binario existe pero no está enlazado:" >&2
  echo "  find / -name gke-gcloud-auth-plugin 2>/dev/null   # añade su carpeta al PATH" >&2
  exit 1
}

if [[ -z "${PROJECT_ID}" ]]; then
  echo "ERROR: PROJECT_ID vacío." >&2
  echo "  gcloud config set project <TU-PROJECT-ID>" >&2
  echo "  ...o bien:  PROJECT_ID=<TU-PROJECT-ID> $0" >&2
  exit 1
fi

# La cuenta tiene que estar autenticada en gcloud. Si no lo está, el primer
# comando fallaría con un mensaje sobre «reauthentication» que no dice cuál.
if ! gcloud auth list --format='value(account)' 2>/dev/null | grep -qx "$CUENTA"; then
  echo "ERROR: la cuenta $CUENTA no está autenticada en gcloud." >&2
  echo "  gcloud auth login $CUENTA" >&2
  exit 1
fi

# Terraform no usa la cuenta de gcloud: usa las «Application Default
# Credentials», que en esta máquina pueden ser de otra cuenta. Se le pasa un
# token de ESTA cuenta. Lo honran el proveedor `google` y el backend `gcs`.
#
# RECIÉN EMITIDO (`--force-auth-refresh`), no el de `print-access-token`:
# ese devuelve el token en caché aunque le queden minutos de vida, y el
# primer `apply` de la fundación murió así —401 a los 5 minutos, con el
# estado sin subir y el candado puesto—.
GOOGLE_OAUTH_ACCESS_TOKEN="$(gcloud config config-helper --force-auth-refresh --format='value(credential.access_token)' 2>/dev/null)" || {
  echo "ERROR: no se pudo obtener un token para $CUENTA (gcloud auth login $CUENTA)." >&2
  exit 1
}
export GOOGLE_OAUTH_ACCESS_TOKEN

# Se imprime en cada script: un despliegue en la nube no debería poder
# equivocarse de proyecto sin que quedara escrito en la salida.
echo "──────────────────────────────────────────────────────────────────────"
printf "  cuenta   %s\n" "$CUENTA"
printf "  proyecto %s · zona %s · clúster %s (%s × %s)\n" \
       "$PROJECT_ID" "$ZONE" "$CLUSTER" "$NUM_NODES" "$MACHINE_TYPE"
printf "  estado    gs://%s\n" "$BUCKET_TFSTATE"
printf "  respaldos gs://%s\n" "$BUCKET_VELERO"
printf "  GitOps    %s (%s)\n" "$GITOPS_URL" "$GITOPS_RAMA"
echo "──────────────────────────────────────────────────────────────────────"
