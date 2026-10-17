# ===========================================================================
# llave.tf — La llave de Sealed Secrets, de vuelta en el clúster.
#
# Criterio 2.4. La llave nació en `00-fundacion/secretos.tf` y vive en Secret
# Manager. Aquí se lee la ÚLTIMA versión y se deja en `kube-system` como el
# controlador la espera:
#
#   · tipo `kubernetes.io/tls`, con `tls.crt` y `tls.key`;
#   · etiqueta `sealedsecrets.bitnami.com/sealed-secrets-key=active`, que es
#     como el controlador distingue sus llaves de cualquier otro Secret TLS.
#
# Al arrancar, el controlador lista los Secret con esa etiqueta; si encuentra
# alguno no genera una llave nueva. Por eso esta llave tiene que existir
# ANTES que el controlador, y por eso ArgoCD depende de ella (`argocd.tf`).
#
# Verificación (lo que hace `scripts/verificar.sh`): la huella del
# certificado que sirve el controlador debe ser idéntica a la del que está en
# Secret Manager y a la de `sealed-secrets/clave-publica.pem` del repositorio.
# ===========================================================================

data "google_secret_manager_secret_version" "llave" {
  secret = local.f.secreto_llave_sealed_secrets
}

locals {
  llave = jsondecode(data.google_secret_manager_secret_version.llave.secret_data)
}

resource "kubernetes_secret_v1" "llave_sealed_secrets" {
  metadata {
    # El nombre es libre; el controlador busca por etiqueta. Uno fijo y
    # reconocible deja claro en `kubectl get secrets -n kube-system` que esta
    # llave vino de fuera y no la generó el controlador
    # (`sealed-secrets-keyXXXXX`).
    name      = "sealed-secrets-llave-p9"
    namespace = "kube-system"
    labels = merge(local.etiquetas, {
      "sealedsecrets.bitnami.com/sealed-secrets-key" = "active"
    })
    annotations = {
      "sa.usac.edu.gt/origen" = "Secret Manager: ${local.f.secreto_llave_sealed_secrets} (versión ${data.google_secret_manager_secret_version.llave.version})"
    }
  }

  type = "kubernetes.io/tls"

  data = {
    "tls.crt" = local.llave["tls.crt"]
    "tls.key" = local.llave["tls.key"]
  }
}
