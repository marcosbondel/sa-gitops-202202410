#!/usr/bin/env bash
# ===========================================================================
# encender.sh — Volver a levantar el entorno al empezar una sesión.
#
#     P9/scripts/encender.sh
#
# Es el punto de entrada único (`bootstrap.sh`): recrea el clúster, ArgoCD
# despliega todo desde Git y el Job de restauración trae los datos del último
# respaldo —el que dejó `apagar.sh`—. Al final, `verificar.sh`. ~35 min.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
"$DIR/bootstrap.sh"
"$DIR/verificar.sh" || true
echo
echo "Al terminar la sesión: P9/scripts/apagar.sh"
