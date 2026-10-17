#!/usr/bin/env bash
# ===========================================================================
# publicar-evidencia.sh — Copia P10/ al repositorio GitOps (público), en
# `evidencia/p10/`, para que la tabla del §4.1 enlace a algo que se abre sin
# autenticación: el repositorio de código es privado.
#
#     P10/scripts/publicar-evidencia.sh
#
# Igual que en la P9: sin el PDF del enunciado (material del curso), sin
# `node_modules` ni `dist`, y sin el correo personal de la cuenta de GCP. No
# hace commit: lo deja preparado para revisarlo.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P10="$(cd "$DIR/.." && pwd)"
GITOPS_DIR="${GITOPS_DIR:-${HOME}/Documents/tech/sa-gitops-202202410}"
DEST="${GITOPS_DIR}/evidencia/p10"

mkdir -p "$DEST"
rsync -a --delete \
  --exclude '.DS_Store' --exclude '*.pdf' --exclude 'node_modules' --exclude 'dist' \
  --exclude '__pycache__' --exclude 'reporte_p10_*.txt' --exclude 'resultados_p10.csv' \
  "$P10/" "$DEST/"

CORREO="${CORREO_PRIVADO:-<cuenta-del-operador>}"
grep -rlI --exclude-dir=.git -F "$CORREO" "$DEST" 2>/dev/null | while read -r f; do
  CORREO="$CORREO" perl -pi -e 's/\Q$ENV{CORREO}\E/<cuenta-del-operador>/g' "$f"
done
quedan=$(grep -rlI -F "$CORREO" "$DEST" 2>/dev/null | wc -l | tr -d ' ')
[[ "$quedan" == "0" ]] || { echo "ERROR: el correo sigue en ${quedan} archivos del espejo" >&2; exit 1; }

echo "Espejado en ${DEST}:"
git -C "$GITOPS_DIR" status --short -- evidencia/p10 | head -40
echo
echo "  git -C ${GITOPS_DIR} add evidencia/p10 && git -C ${GITOPS_DIR} commit -m 'evidencia(p10): …'"
