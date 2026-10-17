# ===========================================================================
# apis.tf — Las APIs de GCP que la práctica necesita.
#
# ## Por qué están aquí y no en el script de arranque
#
# La P6 las habilitaba con `gcloud services enable` dentro de
# `00-crear-cluster.sh`. Funciona, y deja un recurso que nada declara: si
# mañana alguien deshabilita `container.googleapis.com`, no hay un `plan` que
# lo señale.
#
# El motivo real es otro, y es el runbook. Un tercero que reconstruye el
# sistema en un proyecto RECIÉN CREADO se encuentra con que ninguna API está
# habilitada, y el primer error que ve no dice «habilita esta API»: dice que
# el recurso no existe. Declararlas convierte eso en la primera cosa que
# Terraform hace.
#
# ## disable_on_destroy = false
#
# Esta es la bandera que impide que `terraform destroy` sea destructivo de
# verdad. Sin ella, destruir la práctica deshabilitaría `compute` y
# `container` en el proyecto entero —y con ellos cualquier otra cosa que viva
# ahí— y el siguiente `apply` tardaría varios minutos extra esperando a que se
# volvieran a propagar.
#
# Importa especialmente aquí porque el `destroy` NO es un accidente en esta
# práctica: es el escenario que el §3.2 pide ejecutar, con el cronómetro
# corriendo. Un `destroy` que deja el proyecto sin APIs infla el RTO medido
# con minutos que no son del sistema, sino del papeleo de Google.
# ===========================================================================

resource "google_project_service" "requeridas" {
  for_each = toset([
    # El clúster.
    "container.googleapis.com",

    # Las VM de los nodos, los discos persistentes de los PVC y la IP del
    # balanceador. `container` depende de esta, pero Google no lo habilita en
    # cascada.
    "compute.googleapis.com",

    # Los buckets de estado y de respaldos.
    "storage.googleapis.com",

    # El respaldo de la llave de Sealed Secrets. Es la API que convierte la
    # debilidad declarada de la P8 en el criterio 2.4 de esta.
    "secretmanager.googleapis.com",

    # Las cuentas de servicio de Velero y su vínculo con Workload Identity.
    "iam.googleapis.com",
    "iamcredentials.googleapis.com",
  ])

  project = var.project_id
  service = each.value

  # Ver arriba: el `destroy` de esta práctica es un entregable, no un
  # accidente, y no debe dejar el proyecto peor de lo que lo encontró.
  disable_on_destroy = false

  # Un `apply` sobre un proyecto donde la API ya estaba habilitada a mano no
  # debe intentar re-habilitarla y fallar.
  disable_dependent_services = false
}
