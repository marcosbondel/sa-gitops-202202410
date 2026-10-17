# ===========================================================================
# buckets.tf — El bucket de los respaldos de Velero.
#
# El bucket del ESTADO no está aquí: no puede estarlo. Ver `versions.tf`.
#
# ## «Almacenamiento fuera del clúster que se respalda» (§3.2)
#
# La frase descarta las dos soluciones cómodas: un PVC del propio clúster y un
# MinIO corriendo en él. Las dos se pierden con el clúster, que es justo el
# escenario que se prueba. GCS vive en la infraestructura de Google y
# sobrevive a la destrucción del clúster sin que haya que hacer nada.
#
# Velero escribe aquí los MANIFIESTOS de cada respaldo y el índice de los
# snapshots de disco. Los snapshots en sí son objetos de Compute Engine,
# también fuera del clúster y multi-regionales: tampoco mueren con él.
# ===========================================================================

resource "google_storage_bucket" "respaldos" {
  name    = var.bucket_respaldos
  project = var.project_id

  # US multi-regional y no `us-central1`: el respaldo tiene que sobrevivir a
  # la pérdida de la región donde corre el clúster. Un bucket regional junto
  # al clúster sería un punto único de fallo compartido.
  location      = "US"
  storage_class = "STANDARD"

  # Toda la autorización por IAM, ninguna por ACL de objeto: una ACL por
  # objeto puede hacer público un respaldo —la base de datos entera— sin que
  # la política del bucket lo diga.
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  # Con versionado, un `velero backup delete` equivocado deja el objeto como
  # versión no vigente y se puede recuperar. Sin él, un borrado es definitivo.
  versioning {
    enabled = true
  }

  # ## Retención (criterio 2.3)
  #
  # Declarada en dos sitios a propósito: el TTL del Schedule de Velero (30 d)
  # y esta regla (`dias_retencion_respaldos`, más larga). Si Velero deja de
  # correr —justo el caso en que alguien necesita el respaldo— su TTL deja de
  # aplicarse; esta regla sigue funcionando porque la ejecuta GCS.
  lifecycle_rule {
    condition {
      age = var.dias_retencion_respaldos
    }
    action {
      type = "Delete"
    }
  }

  # Las versiones no vigentes que deja el versionado: una semana basta para
  # deshacer un borrado accidental, y sin esta regla el bucket crecería para
  # siempre.
  lifecycle_rule {
    condition {
      days_since_noncurrent_time = 7
      with_state                 = "ARCHIVED"
    }
    action {
      type = "Delete"
    }
  }

  labels = local.etiquetas

  # ## prevent_destroy, y SIN force_destroy
  #
  # Es lo último que un `destroy` debería poder llevarse. Con esta línea,
  # `terraform destroy` sobre la fundación se niega a correr; para borrar el
  # bucket de verdad hay que editar este archivo, que es exactamente la
  # fricción que se quiere delante de una operación irreversible.
  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.requeridas]
}
