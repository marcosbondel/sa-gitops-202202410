#!/usr/bin/env bash
# ===========================================================================
# exportar-tablero.sh — Exporta el tablero de Grafana y le saca una captura.
#
#     P10/scripts/exportar-tablero.sh [<rango>]     # por defecto now-1h
#
#   P10/tablero/tablero-operacion.json   el JSON tal como lo devuelve la API de
#                                        Grafana (`/api/dashboards/uid/…`):
#                                        es lo que se importa en otro Grafana.
#   P10/tablero/captura-tablero.png      el tablero en operación, renderizado
#                                        por Chrome sin interfaz.
#
# El tablero que corre en el clúster sale del repositorio GitOps
# (`observabilidad/config/tableros/`); este script cierra el círculo y deja
# en el repositorio de código la versión exportada del Grafana vivo.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

RANGO="${1:-now-1h}"
UID_TABLERO="sa-p10-operacion"
DEST="${P10_DIR}/tablero"
mkdir -p "$DEST"

abrir_tuneles
CLAVE="$(contrasena_grafana)"
G="http://localhost:${PUERTO_GRAFANA}"
until curl -sf -o /dev/null "$G/api/health"; do sleep 1; done

curl -sf -u "admin:${CLAVE}" "$G/api/dashboards/uid/${UID_TABLERO}" \
  | jq '.dashboard | del(.id)' >"${DEST}/tablero-operacion.json"
echo "✓ ${DEST}/tablero-operacion.json ($(jq '.panels | length' "${DEST}/tablero-operacion.json") paneles)"

CHROME="/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
if [[ -x "$CHROME" ]]; then
  # Grafana permite lectura anónima (ver `apps/51-kube-prometheus-stack.yaml`):
  # Chrome sin interfaz abre el tablero en modo quiosco y lo fotografía.
  PERFIL="$(mktemp -d)"
  URL="${G}/d/${UID_TABLERO}?orgId=1&from=${RANGO}&to=now&kiosk&var-ambiente=sa-p8-prod"
  "$CHROME" --headless=new --disable-gpu --hide-scrollbars --user-data-dir="$PERFIL" \
    --window-size=1920,3400 --virtual-time-budget=25000 \
    --screenshot="${DEST}/captura-tablero.png" "$URL" >/dev/null 2>&1 || true
  rm -rf "$PERFIL"
  [[ -s "${DEST}/captura-tablero.png" ]] && echo "✓ ${DEST}/captura-tablero.png"
fi
