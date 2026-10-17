# ===========================================================================
# main.tf — Proveedor y etiquetas comunes de la FUNDACIÓN.
#
# ## Tres estados, y qué sobrevive a un desastre
#
# La práctica entera gira alrededor de una pregunta: ¿qué se puede volver a
# construir y qué se pierde para siempre? (§1.2, competencia general). La
# respuesta está escrita en la forma de este directorio:
#
#   00-fundacion  DURADERA. Lo que un desastre NO puede llevarse, porque es
#                 lo que hace falta para salir de él: el bucket de respaldos,
#                 la llave de Sealed Secrets en Secret Manager, la IP pública,
#                 las identidades de IAM. Lleva `prevent_destroy` donde
#                 perderlo sería irreversible. Nunca se destruye en la prueba.
#
#   10-cluster    DESECHABLE. El clúster de GKE y su pool de nodos. Es lo que
#                 la prueba de DR destruye con el cronómetro corriendo.
#
#   20-gitops     DESECHABLE. Lo mínimo dentro del clúster para que ArgoCD
#                 tome el control: la llave de Sealed Secrets (leída de
#                 Secret Manager), ArgoCD y la Application raíz. Todo lo demás
#                 lo levanta el app-of-apps desde el repositorio GitOps.
#
# La primera versión de este directorio tenía el clúster y el bucket de
# respaldos en el MISMO estado, con `force_destroy = true` en el bucket. Un
# `terraform destroy` para la prueba de DR se habría llevado los respaldos con
# los que había que recuperarse. Separar las capas es lo que hace que destruir
# el entorno sea seguro de ensayar.
#
# ## Por qué 10 y 20 no son un solo estado
#
# La configuración de un proveedor no puede depender de un recurso creado en
# la misma ejecución: el proveedor `kubernetes` necesita el endpoint del
# clúster, que durante el primer `plan` es `(known after apply)`. A veces
# funciona —cuando el estado ya trae el clúster— y falla justo en el único
# momento que importa: la reconstrucción desde cero. Dos estados encadenados
# por `terraform_remote_state` lo resuelven sin ningún paso manual.
# ===========================================================================

provider "google" {
  project = var.project_id
  region  = var.region
  zone    = var.zone
}

# La identidad con la que se está aplicando. Se usa en `secretos.tf` para
# darle acceso explícito a la llave de Sealed Secrets, de modo que quien
# ejecute el runbook no dependa de que alguien le conceda un rol a mano
# durante el incidente.
data "google_client_openid_userinfo" "yo" {}

locals {
  # Etiquetas de todos los recursos de GCP. `managed-by = terraform` responde
  # con un comando a «¿hay algo creado a mano?»:
  #
  #   gcloud asset search-all-resources --scope=projects/$PROJECT_ID \
  #     --query='labels.managed-by=terraform'
  etiquetas = {
    "part-of"    = "sa-platform"
    "managed-by" = "terraform"
    "practica"   = "p9"
    "carne"      = "202202410"
    "capa"       = "fundacion"
  }
}
