variable "bucket_tfstate" {
  description = "Bucket del estado remoto; se usa para leer las capas anteriores."
  type        = string
}

variable "gitops_url" {
  description = <<-EOT
    Repositorio GitOps, público y separado del de código. Que sea público es
    lo que permite que aquí NO haya ninguna credencial: ArgoCD lo clona de
    forma anónima, y un clúster recién reconstruido no necesita que nadie le
    entregue un token.
  EOT
  type        = string
  default     = "https://github.com/marcosbondel/sa-gitops-202202410.git"
}

variable "gitops_rama" {
  description = "Rama que ArgoCD sigue."
  type        = string
  default     = "main"
}

variable "version_argo_cd" {
  description = "Versión del chart argo-cd. La misma de la P8 (appVersion v3.5.3)."
  type        = string
  default     = "10.9.1"
}
