# ===========================================================================
# versions.tf — Capa DESECHABLE: el arranque de GitOps dentro del clúster.
#
# Prefijo `gitops` en el mismo bucket de estado. Ver `00-fundacion/versions.tf`.
# ===========================================================================
terraform {
  required_version = "~> 1.16"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 2.38"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 2.17"
    }
  }
}
