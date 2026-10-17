# ===========================================================================
# velero-wi.tf — El vínculo de Workload Identity de Velero.
#
# Sustituye a la llave JSON: el ServiceAccount `velero/velero` (que crea el
# chart, desde el repositorio GitOps, con la anotación
# `iam.gke.io/gcp-service-account`) puede actuar como la cuenta de GCP de la
# fundación. Las dos mitades hacen falta y la que falte no se nota hasta el
# primer respaldo.
#
# Vive en esta capa y no en la fundación porque el pool
# `<proyecto>.svc.id.goog` lo crea GCP con el primer clúster que tiene
# Workload Identity; en un proyecto nuevo, un binding que lo nombra antes
# falla con «Identity Pool does not exist».
#
# El `member` tiene una forma exacta y los corchetes son literales. Un error
# aquí no falla al aplicar: falla con un 403 al primer respaldo.
# ===========================================================================

resource "google_service_account_iam_member" "velero_wi" {
  service_account_id = local.f.velero_service_account_id
  role               = "roles/iam.workloadIdentityUser"
  member             = "serviceAccount:${local.f.project_id}.svc.id.goog[velero/velero]"

  depends_on = [google_container_cluster.sa]
}
