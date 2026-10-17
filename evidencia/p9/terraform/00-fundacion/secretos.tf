# ===========================================================================
# secretos.tf — La llave de Sealed Secrets, fuera del clúster.
#
# Criterio 2.4: «Los secretos siguen siendo descifrables tras la
# reconstrucción, con el mecanismo documentado y probado».
#
# ## El problema
#
# El §3.1 lo dice casi con las palabras de `P8/docs/06-secretos.md`: los
# SealedSecret del repositorio GitOps público solo los descifra una llave que
# vivía ÚNICAMENTE dentro del clúster. Destruir el clúster convertía el
# repositorio en criptograma ilegible para siempre.
#
# ## La solución: la llave nace FUERA del clúster
#
# En lugar de dejar que el controlador genere su llave al arrancar y luego
# tratar de rescatarla —con la carrera que eso implica: si el controlador
# arranca antes de que se restaure la llave, genera otra y todo lo sellado con
# la anterior deja de abrirse—, la llave la genera Terraform AQUÍ, en la capa
# que nunca se destruye, y se guarda en Secret Manager.
#
# `20-gitops` la lee de Secret Manager y la deja en `kube-system` con la
# etiqueta `sealedsecrets.bitnami.com/sealed-secrets-key=active` ANTES de que
# ArgoCD instale el controlador. El controlador, al arrancar, encuentra una
# llave activa y la usa en lugar de generar una. El orden lo garantiza el
# grafo de Terraform, no la suerte.
#
# Y el controlador se instala con la renovación automática de llaves APAGADA
# (`keyrenewperiod: 0`, en el repositorio GitOps). Con la renovación por
# defecto —cada 30 días— el controlador generaría una llave nueva DENTRO del
# clúster que nunca llegaría a Secret Manager, y cualquier secreto sellado
# después con ella volvería a tener el problema de la P8.
#
# ## Por qué Sealed Secrets y no External Secrets
#
# El §3.2 admite las dos. External Secrets obligaría a reescribir los 16
# SealedSecret y las Applications que los aplican; respaldar la llave conserva
# el flujo de la P8 intacto y mueve una sola cosa fuera del clúster.
#
# ## Lo que se acepta, dicho para el informe
#
# La llave privada queda en el estado de Terraform (bucket de estado: privado,
# versionado, solo accesible para el operador) además de en Secret Manager. Es
# la misma frontera de confianza: quien puede leer el estado ya puede leer
# Secret Manager. Rotarla es una decisión explícita: `terraform apply
# -replace=tls_private_key.sealed_secrets` y volver a sellar.
# ===========================================================================

resource "tls_private_key" "sealed_secrets" {
  algorithm = "RSA"
  rsa_bits  = 4096
}

# El certificado que el controlador publica y con el que `kubeseal` cifra. Los
# campos imitan los que el propio controlador pone a las llaves que genera.
resource "tls_self_signed_cert" "sealed_secrets" {
  private_key_pem = tls_private_key.sealed_secrets.private_key_pem

  subject {
    common_name  = "sealed-secret"
    organization = "sealed-secret"
  }

  # Diez años. La caducidad del certificado no impide descifrar —el
  # controlador no la comprueba al abrir—, pero `kubeseal --cert` sí avisa al
  # sellar con un certificado vencido.
  validity_period_hours = 87600
  allowed_uses          = ["key_encipherment", "data_encipherment"]
}

resource "google_secret_manager_secret" "llave_sealed_secrets" {
  secret_id = var.secreto_llave_sealed_secrets
  project   = var.project_id

  # Replicación automática y no acotada a una región: la llave tiene que
  # seguir siendo legible si la región del clúster deja de estarlo.
  replication {
    auto {}
  }

  labels = local.etiquetas

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.requeridas]
}

resource "google_secret_manager_secret_version" "llave_sealed_secrets" {
  secret = google_secret_manager_secret.llave_sealed_secrets.id

  # JSON con las dos mitades en PEM: es lo que `20-gitops` necesita para
  # construir el Secret `kubernetes.io/tls` que el controlador reconoce.
  secret_data = jsonencode({
    "tls.crt" = tls_self_signed_cert.sealed_secrets.cert_pem
    "tls.key" = tls_private_key.sealed_secrets.private_key_pem
  })
}

# ---------------------------------------------------------------------------
# Quién puede leer la llave
#
# La identidad que aplica Terraform, que es la misma que ejecuta el runbook.
# Se declara en lugar de depender de que el dueño del proyecto tenga `Owner`
# porque el tercero del §4 lo necesitará explícitamente, y descubrirlo durante
# un incidente cuesta encontrar a quien pueda concederlo.
# ---------------------------------------------------------------------------
resource "google_secret_manager_secret_iam_member" "operador" {
  project   = var.project_id
  secret_id = google_secret_manager_secret.llave_sealed_secrets.secret_id
  role      = "roles/secretmanager.secretAccessor"
  member    = "user:${data.google_client_openid_userinfo.yo.email}"
}
