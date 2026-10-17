# ===========================================================================
# main.tf — Capa desechable: lo que la prueba de DR destruye.
#
# Lee la fundación con `terraform_remote_state` en lugar de recibir sus
# valores por variable: el nombre de la cuenta de servicio de los nodos o el
# proyecto no se copian a mano en ningún sitio, y por tanto no se pueden
# copiar mal durante un incidente.
# ===========================================================================

data "terraform_remote_state" "fundacion" {
  backend = "gcs"
  config = {
    bucket = var.bucket_tfstate
    prefix = "fundacion"
  }
}

locals {
  f = data.terraform_remote_state.fundacion.outputs

  etiquetas = {
    "part-of"    = "sa-platform"
    "managed-by" = "terraform"
    "practica"   = "p9"
    "carne"      = "202202410"
    "capa"       = "cluster"
  }
}

provider "google" {
  project = local.f.project_id
  region  = local.f.region
  zone    = local.f.zona
}
