# ===========================================================================
# main.tf — Lo mínimo dentro del clúster para que ArgoCD tome el control.
#
# El §3.2 lo dice así: «Terraform provisiona el clúster e instala ArgoCD, y a
# partir de ahí el patrón app-of-apps levanta el resto». Esta capa es la
# frontera exacta de esa frase. Crea TRES cosas y ninguna más:
#
#   1. la llave de Sealed Secrets, leída de Secret Manager   (llave.tf)
#   2. ArgoCD                                                (argocd.tf)
#   3. los AppProject y la Application raíz `sa-p9-raiz`     (argocd.tf)
#
# Velero, Kyverno, Argo Rollouts, ingress-nginx, Sealed Secrets, los
# namespaces, las políticas, los secretos, la plataforma y el Schedule de
# respaldos los levanta ArgoCD desde `apps/` del repositorio GitOps. En la P8
# esos complementos los instalaba Terraform; aquí pasan a Git, que es lo que
# hace que la reconstrucción sea una sola orden y no una coreografía.
#
# ## Por qué la llave la pone Terraform y no ArgoCD
#
# Es la única pieza que NO puede venir del repositorio: es un secreto en
# claro, y el repositorio es público. Y tiene que estar en el clúster ANTES
# de que ArgoCD instale el controlador de Sealed Secrets: si el controlador
# arranca sin llave activa, genera una propia y los SealedSecret del
# repositorio dejan de abrirse. El `depends_on` de ArgoCD sobre la llave es lo
# que convierte ese orden en una garantía.
# ===========================================================================

data "terraform_remote_state" "fundacion" {
  backend = "gcs"
  config = {
    bucket = var.bucket_tfstate
    prefix = "fundacion"
  }
}

data "terraform_remote_state" "cluster" {
  backend = "gcs"
  config = {
    bucket = var.bucket_tfstate
    prefix = "cluster"
  }
}

locals {
  f = data.terraform_remote_state.fundacion.outputs
  c = data.terraform_remote_state.cluster.outputs

  etiquetas = {
    "app.kubernetes.io/part-of"    = "sa-platform"
    "app.kubernetes.io/managed-by" = "Terraform"
    "sa.usac.edu.gt/practica"      = "p9"
    "sa.usac.edu.gt/carne"         = "202202410"
  }
}

provider "google" {
  project = local.f.project_id
  region  = local.f.region
}

# El token de acceso de la identidad que aplica. Con él hablan los
# proveedores de Kubernetes y Helm: sin kubeconfig, sin depender de qué
# contexto tenga activo la máquina del operador.
data "google_client_config" "actual" {}

provider "kubernetes" {
  host                   = "https://${local.c.endpoint}"
  token                  = data.google_client_config.actual.access_token
  cluster_ca_certificate = base64decode(local.c.ca)
}

provider "helm" {
  kubernetes {
    host                   = "https://${local.c.endpoint}"
    token                  = data.google_client_config.actual.access_token
    cluster_ca_certificate = base64decode(local.c.ca)
  }
}
