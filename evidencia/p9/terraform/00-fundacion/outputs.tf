# ===========================================================================
# outputs.tf — Lo que las capas desechables y los scripts necesitan saber.
#
# Lo leen `10-cluster` y `20-gitops` con `terraform_remote_state`, no un
# humano con copiar y pegar: es la diferencia entre etapas encadenadas y
# etapas que hay que coordinar a mano.
# ===========================================================================

output "project_id" {
  value = var.project_id
}

output "region" {
  value = var.region
}

output "zona" {
  value = var.zone
}

output "cluster" {
  value = var.cluster
}

output "nodos_service_account" {
  description = "Cuenta de servicio de las VM del pool."
  value       = google_service_account.nodos.email
}

output "bucket_respaldos" {
  description = "Destino de los respaldos de Velero (tabla del §4.1)."
  value       = google_storage_bucket.respaldos.name
}

output "velero_service_account" {
  description = "Cuenta de GCP de Velero; va en la anotación iam.gke.io/gcp-service-account."
  value       = google_service_account.velero.email
}

output "velero_service_account_id" {
  description = "Identificador completo de la cuenta de Velero, para el binding de Workload Identity de `10-cluster`."
  value       = google_service_account.velero.name
}

output "ip_ingress" {
  description = "IP pública reservada del balanceador de ingress-nginx."
  value       = google_compute_address.ingress.address
}

output "secreto_llave_sealed_secrets" {
  description = "Secreto de Secret Manager con la llave de Sealed Secrets."
  value       = google_secret_manager_secret.llave_sealed_secrets.secret_id
}

# El certificado PÚBLICO: con él `kubeseal --cert` sella sin hablar con ningún
# clúster. Se publica en el repositorio GitOps (`sealed-secrets/clave-publica.pem`).
output "certificado_sealed_secrets" {
  description = "Certificado público de Sealed Secrets (PEM)."
  value       = tls_self_signed_cert.sealed_secrets.cert_pem
}

output "resumen" {
  description = "Resumen legible para la evidencia del arranque."
  value       = <<-EOT
    Respaldos     gs://${google_storage_bucket.respaldos.name} (US, versionado, retención GCS ${var.dias_retencion_respaldos} d)
    Velero SA     ${google_service_account.velero.email}
    Nodos SA      ${google_service_account.nodos.email}
    IP pública    ${google_compute_address.ingress.address}
    Llave sellada projects/${var.project_id}/secrets/${google_secret_manager_secret.llave_sealed_secrets.secret_id}
  EOT
}
