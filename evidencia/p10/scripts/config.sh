#!/usr/bin/env bash
# Se carga con `source`: las variables se usan en los scripts que la cargan.
# shellcheck disable=SC2034
# ===========================================================================
# config.sh — Parámetros de los scripts de la Práctica 10.
#
# La P10 corre sobre el mismo clúster que levanta la P9 (`P9/scripts/
# encender.sh`): misma cuenta, mismo proyecto, mismo contexto de kubectl. Así
# que no repite nada de eso: carga `P9/scripts/config.sh` —que fija la
# cuenta y el proyecto explícitamente, pone `gke-gcloud-auth-plugin` en el
# PATH y comprueba las herramientas— y añade solo lo propio de la
# observabilidad.
# ===========================================================================

P10_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Las evidencias de la P10 van a su propia carpeta, no a la de la P9.
EVIDENCIAS="${EVIDENCIAS:-${P10_DIR}/docs/evidencias}"

# shellcheck source=../../P9/scripts/config.sh
source "${P10_DIR}/../P9/scripts/config.sh"

# --- Observabilidad ----------------------------------------------------------
NS_OBS="${NS_OBS:-observabilidad}"
ROLLOUT="${ROLLOUT:-sa-platform-api-gateway}"

# Puertos locales de los túneles (`kubectl port-forward`). Altos y poco
# comunes para no chocar con nada que el operador tenga corriendo.
PUERTO_PROMETHEUS=19090
PUERTO_ALERTMANAGER=19093
PUERTO_TEMPO=13200
PUERTO_LOKI=13100
PUERTO_GRAFANA=13000

# El SLO y la alerta del incidente de producción.
ALERTA_CHECKOUT="CheckoutPresupuestoQuemaRapida"

# Para leer la contraseña de Grafana sin escribirla en ningún archivo.
SECRETO_GRAFANA="grafana-admin"
