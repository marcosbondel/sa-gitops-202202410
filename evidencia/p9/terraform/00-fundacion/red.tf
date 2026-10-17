# ===========================================================================
# red.tf — La IP pública del sistema.
#
# El balanceador de ingress-nginx recibe una IP cuando se crea su Service. Si
# esa IP la eligiera GCP, cada reconstrucción daría una distinta, y con ella
# cambiarían los hosts del Ingress (`sa-p9.<ip>.nip.io`), que viven en el
# repositorio GitOps. Reconstruir exigiría editar Git a mano antes de que el
# sistema respondiera: un paso manual dentro del RTO.
#
# Reservada aquí, en la capa duradera, la IP sobrevive a la destrucción del
# clúster. El clúster nuevo la reclama (`loadBalancerIP` en
# `apps/03-ingress-nginx.yaml`) y las URL públicas son las mismas antes y
# después del desastre. Cuesta ~0.01 USD/hora mientras no está en uso.
#
# Hay una trampa que esto trae y que el runbook cubre: si el clúster muere de
# golpe, la regla de reenvío que GKE creó para el balanceador queda huérfana
# y SIGUE reteniendo la IP. `bootstrap.sh` la libera antes de crear el clúster
# nuevo; sin eso, el Service quedaría en `<pending>` para siempre.
# ===========================================================================

resource "google_compute_address" "ingress" {
  name         = "${var.cluster}-ingress"
  project      = var.project_id
  region       = var.region
  address_type = "EXTERNAL"
  network_tier = "PREMIUM"
  description  = "IP del balanceador de ingress-nginx. Duradera: sobrevive a la reconstrucción del clúster."

  labels = local.etiquetas

  lifecycle {
    prevent_destroy = true
  }

  depends_on = [google_project_service.requeridas]
}
