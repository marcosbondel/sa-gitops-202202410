# ===========================================================================
# versions.tf — Capa DESECHABLE: el clúster de GKE.
#
# Mismo backend que la fundación, con otro prefijo (`cluster`): una capa, un
# estado, un candado. Compartir prefijo haría que las capas se bloquearan
# entre sí sin necesidad. Ver `00-fundacion/versions.tf`.
# ===========================================================================
terraform {
  required_version = "~> 1.16"

  backend "gcs" {}

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }

    # Solo para `time_static`. Ver la política de mantenimiento en `cluster.tf`.
    time = {
      source  = "hashicorp/time"
      version = "~> 0.12"
    }
  }
}
