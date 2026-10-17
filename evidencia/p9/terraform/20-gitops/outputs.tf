output "aplicacion_raiz" {
  description = "Nombre y namespace de la Application raíz (tabla del §4.1)."
  value       = "sa-p9-raiz (namespace argocd)"
}

output "llave_version" {
  description = "Versión de Secret Manager de la que salió la llave instalada."
  value       = data.google_secret_manager_secret_version.llave.version
}
