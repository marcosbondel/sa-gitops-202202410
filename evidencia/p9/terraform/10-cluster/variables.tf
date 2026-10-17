# ===========================================================================
# variables.tf — Dimensionado del clúster.
#
# La cuenta que justifica 3 × e2-standard-4 está en `P9/scripts/config.sh`.
# ===========================================================================

variable "bucket_tfstate" {
  description = "Bucket del estado remoto; se usa para leer la fundación."
  type        = string
}

variable "machine_type" {
  description = "Tipo de máquina de los nodos."
  type        = string
  default     = "e2-standard-4"
}

variable "num_nodes" {
  description = <<-EOT
    Número de nodos. TRES es el mínimo que permite demostrar la resiliencia
    ante pérdida de nodo (§3.2):
      · con 1 no hay drenaje posible —es lo que impedía la P8—;
      · con 2, drenar uno deja a la anti-afinidad sin dónde separar réplicas;
      · con 3, drenar uno deja dos nodos sanos y el planificador reubica las
        réplicas respetando la anti-afinidad y los PodDisruptionBudget.
  EOT
  type        = number
  default     = 3

  validation {
    condition     = var.num_nodes >= 3
    error_message = "Se necesitan al menos 3 nodos para la prueba de pérdida de nodo (§3.2)."
  }
}

variable "disk_type" {
  description = "Disco de los NODOS, no de los PVC."
  type        = string
  default     = "pd-standard"
}

variable "disk_size" {
  description = "Tamaño del disco de cada nodo, en GB."
  type        = number
  default     = 32
}
