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
#   · Se ejecuta también una COPIA corregida del corrector, en /tmp, con la
#     única línea defectuosa arreglada (ver P10/README.md, «El corrector»).
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

# La copia corregida, con DOS arreglos y nada más:
#
#   1. `"${X:-{}}"` deja una `}` pegada al JSON cuando X no está vacía; jq
#      falla y todas las comprobaciones de 2.2 y 2.3 que pasan por esas
#      variables salen en cero.
#   2. `… | grep -qi …` con `set -o pipefail` en dos comprobaciones (Collector
#      y orígenes de Grafana): grep termina en el primer acierto, el comando
#      que escribe en la tubería recibe SIGPIPE y `pipefail` convierte el
#      acierto en fallo. Se cambia `-q` por `>/dev/null`: grep lee todo.
TMP="$(mktemp -d)"
# shellcheck disable=SC2016  # las comillas simples son a propósito: es texto de bash, no se expande aquí
sed -e 's/"\${ATJSON:-{}}"/"${ATJSON:-"{}"}"/g; s/"\${PRJSON:-{}}"/"${PRJSON:-"{}"}"/g' \
    -e 's/| grep -qi "otel/| grep -i >\/dev\/null "otel/' \
    -e 's/echo "\${DS:-}" | grep -qi /echo "${DS:-}" | grep -i >\/dev\/null /' \
    verificar_p10.sh >"$TMP/verificar_p10.sh"
cp p10.conf "$TMP/"
echo
echo "════ Copia con la línea de \${X:-{}} corregida (referencia) ════"
diff verificar_p10.sh "$TMP/verificar_p10.sh" | grep -c '^>' | xargs -I{} echo "  líneas cambiadas: {}"
(cd "$TMP" && env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT -u GOOGLE_OAUTH_ACCESS_TOKEN bash ./verificar_p10.sh) || true
mkdir -p "$EVIDENCIAS"
SELLO="$(date -u +%Y%m%dT%H%M%SZ)"
cp "reporte_p10_202202410.txt" "${EVIDENCIAS}/corrector-original-${SELLO}.txt"
cp "$TMP/reporte_p10_202202410.txt" "${EVIDENCIAS}/corrector-corregido-${SELLO}.txt"
echo
echo "Reportes guardados en docs/evidencias/corrector-{original,corregido}-${SELLO}.txt"
