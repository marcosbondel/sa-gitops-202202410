# ===========================================================================
# variables.tf — Lo que cambia entre una cuenta y otra.
#
# Criterio para que algo sea variable: que tenga un valor distinto en algún
# entorno real. Y aquí hay uno que no es hipotético: el proyecto del tercero
# que ejecuta el runbook (§3.2). Si algo fuera una constante, tendría que
# editar un `.tf` durante el incidente.
# ===========================================================================

variable "project_id" {
  description = "Proyecto de GCP. Sin valor por defecto: un proyecto equivocado no falla, crea recursos facturables en la cuenta de otro."
  type        = string
}

variable "region" {
  description = "Región de la IP del balanceador."
  type        = string
  default     = "us-central1"
}

variable "zone" {
  description = "Zona del clúster. La usa solo el proveedor; el clúster vive en `10-cluster`."
  type        = string
  default     = "us-central1-a"
}

variable "cluster" {
  description = "Nombre del clúster. Aquí solo da nombre a la cuenta de servicio de los nodos y a la IP."
  type        = string
  default     = "sa-p9"
}

variable "bucket_respaldos" {
  description = "Bucket de GCS donde Velero escribe. Fuera del clúster que respalda (§3.2)."
  type        = string
}

variable "secreto_llave_sealed_secrets" {
  description = "Secreto de Secret Manager con la llave de Sealed Secrets. Ver `secretos.tf`."
  type        = string
  default     = "sa-p9-sealed-secrets-llave"
}

variable "dias_retencion_respaldos" {
  description = <<-EOT
    Días que un objeto vive en el bucket antes de que GCS lo borre. Es el
    segundo cinturón: el primero es el TTL del Schedule de Velero (30 días).
    Más largo a propósito: si Velero deja de correr, su TTL deja de
    aplicarse y esta regla —que ejecuta GCS— sigue funcionando; y el orden
    de los borrados queda correcto: primero el que sabe lo que borra.
  EOT
  type        = number
  default     = 45
}
