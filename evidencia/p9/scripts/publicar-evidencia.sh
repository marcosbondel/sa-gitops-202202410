#!/usr/bin/env bash
# ===========================================================================
# publicar-evidencia.sh — Espeja la evidencia en el repositorio PÚBLICO.
#
#     P9/scripts/publicar-evidencia.sh
#
# El repositorio de código es privado, y el §4.1 califica con cero «un enlace
# que requiera autenticación». Así que la documentación y la evidencia de la
# P9 se copian a `evidencia/p9/` del repositorio GitOps, que es público, y la
# tabla de enlaces del README apunta allí.
#
# Copia, no mueve: el original sigue en `P9/docs/`. Deja el cambio listo para
# commit en el repositorio GitOps, sin empujarlo.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
P9="$(cd "$DIR/.." && pwd)"
GITOPS_DIR="${GITOPS_DIR:-${HOME}/Documents/tech/sa-gitops-202202410}"
DEST="${GITOPS_DIR}/evidencia/p9"

mkdir -p "$DEST"
rsync -a --delete --exclude '.DS_Store' --exclude '*.pdf' --exclude '*.parar' --exclude 'parar-escritor' \
  "$P9/docs/" "$DEST/docs/"
cp "$P9/README.md" "$DEST/README.md"
rsync -a --delete --exclude '.terraform' --exclude '*.tfstate*' "$P9/terraform/" "$DEST/terraform/"
rsync -a --delete "$P9/scripts/" "$DEST/scripts/"

# El repositorio GitOps es PÚBLICO: el correo de la cuenta del operador (que
# aparece en `config.sh` y en la cabecera de cada registro) no se publica.
CORREO="${CORREO_PRIVADO:-<cuenta-del-operador>}"
grep -rlI --exclude-dir=.git -F "$CORREO" "$DEST" 2>/dev/null | while read -r f; do
  CORREO="$CORREO" perl -pi -e 's/\Q$ENV{CORREO}\E/<cuenta-del-operador>/g' "$f"
done
quedan=$(grep -rlI -F "$CORREO" "$DEST" 2>/dev/null | wc -l | tr -d ' ')
[[ "$quedan" == "0" ]] || { echo "ERROR: el correo sigue en ${quedan} archivos del espejo" >&2; exit 1; }

# El README espejado enlaza rutas relativas de P9/; en el espejo son las mismas.
echo "Espejado en ${DEST}:"
git -C "$GITOPS_DIR" status --short -- evidencia/p9 | head -40
echo
echo "  git -C ${GITOPS_DIR} add evidencia/p9 && git -C ${GITOPS_DIR} commit -m 'evidencia(p9): …'"
