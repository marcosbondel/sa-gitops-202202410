#!/usr/bin/env bash
# ===========================================================================
# preparar-calificacion.sh — Deja la máquina lista para que el auxiliar
# ejecute `verificar_p10.sh`, y lo ejecuta.
#
#     P10/scripts/preparar-calificacion.sh
#
# El corrector usa el `kubectl` y el `gcloud` del entorno tal como estén. En
# esta máquina la configuración activa de gcloud es OTRA cuenta y el plugin
# de autenticación de GKE no está en el PATH por defecto: sin preparar, el
# corrector diría «SIN ACCESO AL CLUSTER» y lo marcaría como eliminatorio.
# Los pasos son los mismos que en la P9 (`P9/scripts/preparar-calificacion.sh`).
#
# Además:
#   · `verificar_p10.sh` usa `mapfile` (bash 4+); el bash de macOS es 3.2. Se
#     antepone el de Homebrew al PATH.
#   · Se ejecuta también `verificar_p10_corregido.sh`, la copia con los dos
#     defectos del corrector arreglados (docs/06-defectos-del-corrector.md).
#     El original, sin tocar, es el que cuenta.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"

if ! gcloud config configurations describe sa-p9 >/dev/null 2>&1; then
  gcloud config configurations create sa-p9 --no-activate >/dev/null
fi
gcloud config configurations activate sa-p9 >/dev/null
env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT gcloud config set account "$CUENTA" >/dev/null 2>&1
env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT \
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT_ID" >/dev/null
echo "✓ gcloud: configuración sa-p9 (${PROJECT_ID}) · kubectl: $(kubectl config current-context)"

PLUGIN_DIR="$(dirname "$(command -v gke-gcloud-auth-plugin)")"
export PATH="/opt/homebrew/bin:${PLUGIN_DIR}:${PATH}"
bash --version | head -1 | grep -q 'version [4-9]' || { echo "✗ se necesita bash 4 o superior (brew install bash)" >&2; exit 1; }
echo "✓ $(bash --version | head -1)"

cd "$DIR"
echo
echo "════ Corrector oficial (sin modificar) ════"
env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT -u GOOGLE_OAUTH_ACCESS_TOKEN bash ./verificar_p10.sh || true

# Referencia: `verificar_p10_corregido.sh`, la copia con solo los dos defectos
# del corrector arreglados (ver docs/06-defectos-del-corrector.md). Escribe su
# propio reporte, así que no pisa el del original.
echo
echo "════ Copia corregida (referencia) ════"
env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT -u GOOGLE_OAUTH_ACCESS_TOKEN bash ./verificar_p10_corregido.sh || true

mkdir -p "$EVIDENCIAS"
SELLO="$(date -u +%Y%m%dT%H%M%SZ)"
sed 's/\x1b\[[0-9;]*m//g' "reporte_p10_202202410.txt" >"${EVIDENCIAS}/corrector-original-${SELLO}.txt"
sed 's/\x1b\[[0-9;]*m//g' "reporte_p10_202202410_corregido.txt" >"${EVIDENCIAS}/corrector-corregido-${SELLO}.txt"
echo
echo "Reportes guardados en docs/evidencias/corrector-{original,corregido}-${SELLO}.txt"
