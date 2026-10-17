# ===========================================================================
# argocd.tf — ArgoCD y la semilla del app-of-apps.
# ===========================================================================

resource "helm_release" "argocd" {
  name             = "argocd"
  repository       = "https://argoproj.github.io/argo-helm"
  chart            = "argo-cd"
  version          = var.version_argo_cd
  namespace        = "argocd"
  create_namespace = true

  # Ver `llave.tf`: el controlador de Sealed Secrets que ArgoCD va a instalar
  # tiene que encontrar la llave ya puesta.
  depends_on = [kubernetes_secret_v1.llave_sealed_secrets]

  values = [yamlencode({
    configs = {
      params = {
        # Sin TLS en el servidor: se accede por `kubectl port-forward`, que ya
        # va cifrado dentro del túnel de la API de Kubernetes. La interfaz NO
        # se expone a Internet: es la consola con permiso de desplegar.
        "server.insecure" = true
      }

      cm = {
        # Comprobar el repositorio cada 30 s en lugar de cada 3 min. Cada
        # ciclo de espera de ArgoCD es tiempo que cuenta en el RTO.
        "timeout.reconciliation" = "30s"

        # Las ClusterRole agregadas (las de Kyverno, por ejemplo) las rellena
        # el plano de control; sin esto aparecen siempre como OutOfSync.
        "resource.compareoptions" = yamlencode({
          ignoreAggregatedRoles = true
        })

        # ## Lo que ArgoCD NO debe seguir: los objetos de ejecución de Velero
        #
        # Velero copia las anotaciones del Schedule a cada Backup que genera,
        # incluida la marca de seguimiento de ArgoCD. Sin esta exclusión,
        # ArgoCD cree que los Backup son suyos, los ve fuera de Git y —con
        # `prune: true`— puede BORRARLOS. Observado en la primera
        # reconstrucción real: la Application de respaldos listaba los Backup
        # como recursos propios. Las demás reglas son las que el chart trae
        # por defecto: definir la clave las reemplaza, así que se repiten.
        "resource.exclusions" = <<-YAML
          ### Network resources created by the Kubernetes control plane and excluded to reduce the number of watched events and UI clutter
          - apiGroups:
            - ''
            - discovery.k8s.io
            kinds:
            - Endpoints
            - EndpointSlice
          ### Internal Kubernetes resources excluded reduce the number of watched events
          - apiGroups:
            - coordination.k8s.io
            kinds:
            - Lease
          ### Internal Kubernetes Authz/Authn resources excluded reduce the number of watched events
          - apiGroups:
            - authentication.k8s.io
            - authorization.k8s.io
            kinds:
            - SelfSubjectReview
            - TokenReview
            - LocalSubjectAccessReview
            - SelfSubjectAccessReview
            - SelfSubjectRulesReview
            - SubjectAccessReview
          ### Intermediate Certificate Request excluded reduce the number of watched events
          - apiGroups:
            - certificates.k8s.io
            kinds:
            - CertificateSigningRequest
          - apiGroups:
            - cert-manager.io
            kinds:
            - CertificateRequest
          ### Cilium internal resources excluded reduce the number of watched events and UI Clutter
          - apiGroups:
            - cilium.io
            kinds:
            - CiliumIdentity
            - CiliumEndpoint
            - CiliumEndpointSlice
          ### Kyverno intermediate and reporting resources excluded reduce the number of watched events and improve performance
          - apiGroups:
            - kyverno.io
            - reports.kyverno.io
            - wgpolicyk8s.io
            kinds:
            - PolicyReport
            - ClusterPolicyReport
            - EphemeralReport
            - ClusterEphemeralReport
            - AdmissionReport
            - ClusterAdmissionReport
            - BackgroundScanReport
            - ClusterBackgroundScanReport
            - UpdateRequest
          - apiGroups:
            - velero.io
            kinds:
            - Backup
            - Restore
            - DeleteBackupRequest
            - DownloadRequest
            - ServerStatusRequest
            - PodVolumeBackup
            - PodVolumeRestore
            - DataUpload
            - DataDownload
            - BackupRepository
            clusters:
            - '*'
        YAML

        # ## La salud de una Application
        #
        # Esta es la pieza sin la cual el app-of-apps NO respeta el orden.
        #
        # Desde ArgoCD 1.8 la salud de una Application hija no cuenta para la
        # salud de su madre: la raíz aplica la ola -40, ve que las Application
        # se crearon, y pasa a la siguiente ola sin esperar a que Velero o
        # Kyverno estén de verdad arriba. El Job de restauración (ola -15)
        # arrancaría antes de que existiera el CRD `Restore`, y la plataforma
        # (ola 0) crearía PostgreSQL con un volumen VACÍO antes de que Velero
        # trajera el de verdad: `initdb` correría sobre él y los datos
        # restaurados se perderían por segunda vez.
        #
        # Con este script, la raíz espera a que cada Application de una ola
        # esté `Healthy` antes de aplicar la siguiente. Es la línea que hace
        # que el orden del diagrama del bootstrap sea el orden real.
        #
        # Solo cuenta como sana una Application `Healthy` Y `Synced`; solo
        # `Degraded` hace fallar; todo lo demás es `Progressing` (esperar).
        #
        # Las dos condiciones salen de la primera reconstrucción real en GKE:
        #   · recién creada, una Application sin recursos todavía reporta
        #     `Healthy` —un conjunto vacío está sano— y la raíz pasaba a la
        #     ola siguiente: la plataforma (ola 0) arrancó con el Job de
        #     restauración (ola -15) aún corriendo;
        #   · antes de sincronizar reporta `Missing`, y ArgoCD no espera ante
        #     `Missing`.
        # Exigir `Synced` cierra las dos: hasta que sus recursos existen, una
        # Application recién creada está `OutOfSync`.
        "resource.customizations.health.argoproj.io_Application" = <<-LUA
          hs = {}
          hs.status = "Progressing"
          hs.message = "esperando a la Application"
          if obj.status ~= nil and obj.status.health ~= nil then
            local h = obj.status.health.status
            local s = "?"
            if obj.status.sync ~= nil and obj.status.sync.status ~= nil then
              s = obj.status.sync.status
            end
            if h == "Degraded" then
              hs.status = "Degraded"
            elseif h == "Healthy" and s == "Synced" then
              hs.status = "Healthy"
            end
            if obj.status.health.message ~= nil then
              hs.message = obj.status.health.message
            else
              hs.message = "salud " .. tostring(h) .. ", sincronización " .. s
            end
          end
          return hs
        LUA

        # ## La salud del destino de los respaldos
        #
        # Sin esto, la Application de Velero está `Healthy` en cuanto su
        # Deployment arranca, aunque el bucket sea inalcanzable —por ejemplo,
        # mientras IAM todavía propaga el binding de Workload Identity—. Con
        # esto, la ola de Velero no termina hasta que el BackupStorageLocation
        # está `Available`, y el Job de restauración de la ola siguiente no
        # arranca contra un bucket que aún no puede leer.
        #
        # `Unavailable` se reporta como `Progressing` y no como `Degraded`: es
        # el estado normal de los primeros segundos, y `Degraded` haría fallar
        # la sincronización de la raíz en lugar de esperarla.
        "resource.customizations.health.velero.io_BackupStorageLocation" = <<-LUA
          hs = {}
          hs.status = "Progressing"
          hs.message = "Validando el acceso al bucket"
          if obj.status ~= nil and obj.status.phase == "Available" then
            hs.status = "Healthy"
            hs.message = "Bucket accesible"
          elseif obj.status ~= nil and obj.status.message ~= nil then
            hs.message = obj.status.message
          end
          return hs
        LUA
      }
    }

    dex            = { enabled = false }
    notifications  = { enabled = false }
    applicationSet = { replicas = 0 }
  })]

  wait    = true
  timeout = 900
}

# ---------------------------------------------------------------------------
# La semilla: dos AppProject y la Application raíz.
#
# Un chart local y no `kubernetes_manifest`: este último necesita que el CRD
# `Application` exista durante el `plan`, y en una reconstrucción desde cero
# el CRD lo crea el `helm_release` de arriba en el MISMO `apply`. Con un chart
# local, el CRD solo se consulta al instalar, cuando ya existe.
# ---------------------------------------------------------------------------
resource "helm_release" "semilla" {
  name      = "sa-p9-semilla"
  chart     = "${path.module}/semilla"
  namespace = "argocd"

  depends_on = [helm_release.argocd]

  values = [yamlencode({
    gitopsUrl  = var.gitops_url
    gitopsRama = var.gitops_rama
    etiquetas  = local.etiquetas
  })]

  wait    = true
  timeout = 300
}
