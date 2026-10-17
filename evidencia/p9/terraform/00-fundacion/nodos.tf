# ===========================================================================
# nodos.tf — La identidad de las VM del clúster.
#
# No es la de Velero —esa está en `velero.tf`—. Es la cuenta con la que el
# kubelet escribe logs y métricas.
#
# Se crea una propia en lugar de usar la de Compute Engine por defecto, que
# trae el rol `Editor` sobre el proyecto ENTERO: cualquier pod que alcanzara
# el token de la VM podría borrar el bucket de respaldos. Esta cuenta puede
# hacer las cuatro cosas que un nodo necesita y ninguna más.
#
# ## Por qué en la fundación y no junto al clúster
#
# Porque sobrevive al desastre, y eso acorta el RTO. Las cuentas de servicio y
# sus roles tardan en propagarse por IAM; recrearlas en cada reconstrucción
# añadiría esa espera —y un riesgo de 403 transitorio en el primer arranque de
# los nodos— al tiempo medido. La identidad no es parte de lo que se pierde.
# ===========================================================================

resource "google_service_account" "nodos" {
  account_id   = "${var.cluster}-nodos"
  display_name = "Nodos del clúster ${var.cluster} (P9)"
  project      = var.project_id

  depends_on = [google_project_service.requeridas]
}

resource "google_project_iam_member" "nodos" {
  for_each = toset([
    # Logs y métricas. Sin ellos Cloud Logging queda vacío, y con él la única
    # evidencia del RTO que no depende del reloj de la laptop.
    "roles/logging.logWriter",
    "roles/monitoring.metricWriter",
    "roles/monitoring.viewer",
    "roles/stackdriver.resourceMetadata.writer",
  ])

  project = var.project_id
  role    = each.value
  member  = "serviceAccount:${google_service_account.nodos.email}"
}
