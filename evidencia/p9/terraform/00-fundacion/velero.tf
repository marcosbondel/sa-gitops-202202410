# ===========================================================================
# velero.tf — La identidad con la que Velero habla con GCP.
#
# El servidor de Velero lo instala ArgoCD desde el repositorio GitOps
# (`apps/06-velero.yaml`). Lo que hay aquí es solo la mitad de GCP: una cuenta
# de servicio y sus permisos.
#
# La división no es arbitraria: esta mitad SOBREVIVE al clúster. Es la pieza
# que hace que un clúster recién reconstruido pueda leer los respaldos del
# anterior sin que nadie copie una credencial, y por tanto es la que hace que
# la restauración del §3.2 sea posible en el escenario que importa —el clúster
# destruido— y no solo en el cómodo.
#
# ## Lo que Velero necesita poder hacer, y nada más
#
# Hay un rol que resolvería esto en una línea: `roles/storage.admin` sobre el
# proyecto. No se usa, porque incluye borrar buckets ajenos. Lo que se concede
# son tres permisos distintos sobre tres ámbitos distintos:
#
#   objetos del bucket de respaldos  →  leer, escribir, borrar
#   discos y snapshots de Compute    →  crear snapshots y restaurarlos
#   nada más
# ===========================================================================

resource "google_service_account" "velero" {
  account_id   = "sa-p9-velero"
  display_name = "Velero · respaldos de la Práctica 9"
  description  = "Escribe en gs://${var.bucket_respaldos} y gestiona snapshots de disco. Vinculada por Workload Identity a velero/velero."
  project      = var.project_id

  depends_on = [google_project_service.requeridas]
}

# ---------------------------------------------------------------------------
# Permiso sobre el bucket, y SOLO sobre este bucket
#
# `google_storage_bucket_iam_member` y no `google_project_iam_member`: el rol
# se concede en el ámbito del bucket. La diferencia práctica es que Velero no
# puede tocar el bucket del ESTADO de Terraform, que vive en el mismo
# proyecto.
#
# Que no pueda importa más de lo que parece. Velero corre dentro del clúster,
# y el clúster ejecuta manifiestos que vienen de un repositorio público. Si su
# identidad pudiera escribir en el bucket de estado, un manifiesto malicioso
# —o un error— podría corromper el mapa de la infraestructura, y la
# reconstrucción automática del §3.2 dejaría de ser posible. El respaldo y el
# estado se protegen el uno del otro.
# ---------------------------------------------------------------------------
resource "google_storage_bucket_iam_member" "velero_objetos" {
  bucket = google_storage_bucket.respaldos.name

  # `objectAdmin` y no `admin`: puede crear, leer y borrar OBJETOS, y no puede
  # cambiar la configuración del bucket —ni su política de retención, ni el
  # versionado, ni borrarlo—. Velero necesita borrar objetos para aplicar el
  # TTL de sus Backup; no necesita poder desactivar la retención que los
  # protege.
  role   = "roles/storage.objectAdmin"
  member = "serviceAccount:${google_service_account.velero.email}"
}

# Listar el contenido del bucket. `objectAdmin` no incluye `storage.buckets.get`,
# y Velero lo llama al validar el BackupStorageLocation al arrancar.
#
# Sin este rol, el síntoma es un BackupStorageLocation en estado `Unavailable`
# con un 403 que menciona `storage.buckets.get` —legible, por una vez—, pero
# el respaldo programado nunca se ejecuta y nada más lo señala.
resource "google_storage_bucket_iam_member" "velero_bucket" {
  bucket = google_storage_bucket.respaldos.name
  role   = "roles/storage.legacyBucketReader"
  member = "serviceAccount:${google_service_account.velero.email}"
}

# ---------------------------------------------------------------------------
# Permiso sobre los discos persistentes
#
# Para los snapshots de volumen. Es un rol a nivel de PROYECTO porque los
# discos de los PVC los crea GKE con nombres que Terraform no conoce: no hay
# un recurso sobre el que acotar el permiso.
#
# `compute.storageAdmin` cubre discos, imágenes y snapshots, y no toca
# instancias ni redes. Es el rol que la documentación de
# `velero-plugin-for-gcp` pide, y la acotación posible es ésta: el proyecto,
# en el que no vive nada más que esta práctica.
# ---------------------------------------------------------------------------
resource "google_project_iam_member" "velero_discos" {
  project = var.project_id
  role    = "roles/compute.storageAdmin"
  member  = "serviceAccount:${google_service_account.velero.email}"
}

# ---------------------------------------------------------------------------
# Firmar URLs con su propia identidad
#
# `velero backup logs` y `velero backup describe --details` no leen el bucket
# directamente: le piden al servidor una URL firmada. Con Workload Identity no
# hay llave privada con la que firmar, así que el plugin de GCP firma a través
# de la API de IAM (`signBlob`), y para eso la cuenta necesita este rol SOBRE
# SÍ MISMA. Sin él los respaldos funcionan, pero inspeccionarlos durante un
# incidente falla con un 403 que no menciona la firma.
# ---------------------------------------------------------------------------
resource "google_service_account_iam_member" "velero_firma" {
  service_account_id = google_service_account.velero.name
  role               = "roles/iam.serviceAccountTokenCreator"
  member             = "serviceAccount:${google_service_account.velero.email}"
}

# El vínculo de Workload Identity (`velero/velero` → esta cuenta) NO está
# aquí: está en `10-cluster/velero-wi.tf`. El pool `<proyecto>.svc.id.goog` lo
# crea GCP al crear el primer clúster con Workload Identity, y un binding que
# lo nombra antes de que exista falla con «Identity Pool does not exist». En
# un proyecto recién creado —el del tercero del runbook— esta capa se aplica
# antes que cualquier clúster.
