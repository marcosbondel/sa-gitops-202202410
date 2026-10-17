# Lo que `20-gitops` lee para hablar con el clúster recién creado.

output "cluster" {
  value = google_container_cluster.sa.name
}

output "endpoint" {
  value = google_container_cluster.sa.endpoint
}

output "ca" {
  # Es una clave pública, pero el proveedor la marca sensible por venir de
  # `master_auth`; contradecirlo la imprimiría entera en cada `apply`.
  value     = google_container_cluster.sa.master_auth[0].cluster_ca_certificate
  sensitive = true
}

output "kube_context" {
  description = "Contexto que deja `gcloud container clusters get-credentials`."
  value       = "gke_${local.f.project_id}_${local.f.zona}_${google_container_cluster.sa.name}"
}

# El pool de nodos como dependencia explícita: `20-gitops` no debe instalar
# nada hasta que haya nodos donde ponerlo. Leer este output fuerza el orden.
output "pool" {
  value = google_container_node_pool.principal.name
}

output "resumen" {
  value = <<-EOT
    Clúster       ${google_container_cluster.sa.name} (${local.f.zona}) · ${var.num_nodes} × ${var.machine_type}
    Dataplane     ${google_container_cluster.sa.datapath_provider}
    Canal         STABLE · exclusión «practica-9» de 30 días
  EOT
}
