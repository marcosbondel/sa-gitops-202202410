# ===========================================================================
# versions.tf — Proveedores, versiones y el backend remoto.
#
# ## El backend (criterio 2.2)
#
# `backend "gcs"` PARCIAL a propósito: no declara `bucket`. Los nombres de
# bucket son globales en todo GCS y dependen del PROJECT_ID; escribirlo aquí
# ataría el repositorio a un proyecto y le impediría a un tercero ejecutar el
# runbook en el suyo. Lo pasa el punto de entrada único:
#
#     terraform init -reconfigure \
#       -backend-config="bucket=${BUCKET_TFSTATE}" \
#       -backend-config="prefix=fundacion"
#
# ## El bloqueo
#
# El backend de GCS bloquea de serie, sin tabla aparte: escribe un objeto
# `default.tflock` junto al estado usando precondiciones de generación de la
# API de GCS, que son atómicas del lado del servidor. Dos `apply` a la vez: el
# segundo falla con «Error acquiring the state lock» en lugar de corromper el
# estado. `P9/scripts/prueba-bloqueo.sh` lo demuestra.
#
# ## El huevo y la gallina del bucket de estado
#
# El bucket que guarda el estado no puede declararse en este estado: Terraform
# necesita leerlo ANTES de saber si existe. Lo crea `bootstrap.sh` con
# `gcloud storage buckets create`, de forma idempotente, versionado y con
# acceso público bloqueado. Es la única pieza de la práctica que no nace de
# Terraform, y la alternativa —declararlo aquí con estado local— devolvería al
# repositorio el archivo de estado que el §8.1 prohíbe.
# ===========================================================================
terraform {
  required_version = "~> 1.16"

  backend "gcs" {
    # Intencionadamente vacío. Ver arriba.
  }

  required_providers {
    google = {
      source  = "hashicorp/google"
      version = "~> 6.0"
    }

    # Genera la llave de Sealed Secrets. Ver `secretos.tf`.
    tls = {
      source  = "hashicorp/tls"
      version = "~> 4.0"
    }
  }
}
