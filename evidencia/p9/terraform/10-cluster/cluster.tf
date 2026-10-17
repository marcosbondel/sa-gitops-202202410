# ===========================================================================
# cluster.tf — El clúster de GKE y su pool de nodos.
#
# En la P8 el clúster lo creaba `00-crear-cluster.sh` con `kind create
# cluster`: un paso imperativo que ningún `plan` podía verificar. Aquí lo
# declara Terraform, y es lo primero que el punto de entrada único vuelve a
# levantar después de un desastre.
#
# ## El pool por separado
#
# `remove_default_node_pool = true` + un `google_container_node_pool` aparte.
# El pool por defecto no se puede modificar sin recrear el clúster; con el
# pool declarado aparte, cambiar `machine_type` recrea solo el pool y deja el
# plano de control en pie.
# ===========================================================================

resource "google_container_cluster" "sa" {
  name     = local.f.cluster
  location = local.f.zona

  # Desde la versión 5 del proveedor el clúster nace con
  # `deletion_protection = true`, y `terraform destroy` falla. Aquí destruirlo
  # ES el entregable (§3.2): descubrir esta bandera con el cronómetro
  # corriendo costaría minutos de RTO que no son del sistema.
  deletion_protection = false

  # GKE no permite crear un clúster sin nodos: se crea con uno y se borra en
  # el mismo `apply`. El pool real es el recurso de abajo.
  initial_node_count       = 1
  remove_default_node_pool = true

  # Dataplane V2 (Cilium/eBPF). Solo se puede elegir AL CREAR el clúster, y
  # sin él el clúster acepta los 23 `NetworkPolicy` del chart de la
  # plataforma y no aplica ninguno, sin un aviso en ninguna parte.
  datapath_provider = "ADVANCED_DATAPATH"

  # VPC-nativo: obligatorio para Dataplane V2.
  ip_allocation_policy {}

  # Desde 2026 un clúster nuevo no puede quedarse fuera de un canal.
  # STABLE es el más conservador; la exclusión de mantenimiento de abajo
  # impide que una actualización automática drene nodos en mitad de una
  # prueba y falsee el RTO o la prueba de pérdida de nodo.
  release_channel {
    channel = "STABLE"
  }

  # Workload Identity: Velero se autentica ante GCS SIN una llave JSON en un
  # Secret. La alternativa tendría un problema circular —la credencial para
  # LEER los respaldos viviría dentro del clúster que se respalda—, que es el
  # mismo error que la P8 cometió con la llave de Sealed Secrets.
  workload_identity_config {
    workload_pool = "${local.f.project_id}.svc.id.goog"
  }

  addons_config {
    # El driver CSI de discos persistentes: provisiona los PVC de PostgreSQL
    # y RabbitMQ, que son los volúmenes que Velero respalda con snapshots.
    gce_persistent_disk_csi_driver_config {
      enabled = true
    }

    horizontal_pod_autoscaling {
      disabled = false
    }

    # El controlador de Ingress de Google, APAGADO: el canary de la P8
    # reparte tráfico con anotaciones de ingress-nginx. Dos controladores
    # reclamando los mismos Ingress harían el reparto no determinista.
    http_load_balancing {
      disabled = true
    }
  }

  # La fecha viene de un `time_static`, que congela el instante del primer
  # `apply`. Con `timestamp()` cada `plan` mostraría el clúster como
  # modificado, y `terraform plan` dejaría de poder decir «nada cambió».
  maintenance_policy {
    recurring_window {
      start_time = time_static.creacion.rfc3339
      end_time   = timeadd(time_static.creacion.rfc3339, "4h")
      recurrence = "FREQ=WEEKLY;BYDAY=SA,SU"
    }

    maintenance_exclusion {
      exclusion_name = "practica-9"
      start_time     = time_static.creacion.rfc3339
      end_time       = timeadd(time_static.creacion.rfc3339, "720h") # 30 días
      exclusion_options {
        scope = "NO_UPGRADES"
      }
    }
  }

  # Sin certificados de cliente: la única vía al servidor de API es OIDC a
  # través de `gcloud`.
  master_auth {
    client_certificate_config {
      issue_client_certificate = false
    }
  }

  resource_labels = local.etiquetas

  lifecycle {
    # GKE reescribe la versión con la del canal; sin esto cada `plan`
    # propondría bajarla.
    ignore_changes = [min_master_version]
  }
}

resource "time_static" "creacion" {}

resource "google_container_node_pool" "principal" {
  name     = "${local.f.cluster}-principal"
  location = local.f.zona
  cluster  = google_container_cluster.sa.name

  node_count = var.num_nodes

  node_config {
    machine_type = var.machine_type
    disk_type    = var.disk_type
    disk_size_gb = var.disk_size

    # La identidad mínima de `00-fundacion/nodos.tf`, que sobrevive al
    # desastre y por eso no hay que esperar a que IAM la propague.
    service_account = local.f.nodos_service_account

    # Un solo scope, el amplio: los scopes son un filtro SOBRE los roles de
    # IAM, y con la cuenta mínima de arriba Google recomienda gobernar los
    # permisos en un único sitio.
    oauth_scopes = ["https://www.googleapis.com/auth/cloud-platform"]

    # Lo que activa Workload Identity EN LOS NODOS. Sin esta línea los pods
    # heredan la identidad de la VM y la anotación del ServiceAccount de
    # Velero no sirve de nada; el síntoma es un 403 al primer respaldo.
    workload_metadata_config {
      mode = "GKE_METADATA"
    }

    tags = ["sa-p9", "gke-nodo"]

    metadata = {
      "disable-legacy-endpoints" = "true"
    }

    resource_labels = local.etiquetas
  }

  management {
    # No se pueden apagar dentro de un canal; los contiene la exclusión de
    # mantenimiento del clúster.
    auto_repair  = true
    auto_upgrade = true
  }

  # Una actualización añade un nodo nuevo antes de drenar uno viejo. Con el
  # defecto (`max_unavailable = 1`) una actualización provocaría sin querer
  # el drenaje que el §3.2 quiere provocar a mano y medir.
  upgrade_settings {
    max_surge       = 1
    max_unavailable = 0
    strategy        = "SURGE"
  }

  lifecycle {
    ignore_changes = [version]
  }
}
