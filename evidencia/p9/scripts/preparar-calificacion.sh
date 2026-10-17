#!/usr/bin/env bash
# ===========================================================================
# preparar-calificacion.sh — Deja ESTA máquina lista para el corrector.
#
#     P9/scripts/preparar-calificacion.sh
#
# El corrector (`verificar_p9.sh`) corre `kubectl` y `velero` tal cual, en
# una terminal nueva, sin nuestras variables de entorno. Dos cosas de esta
# máquina lo harían fallar con «SIN ACCESO AL CLUSTER», que es eliminatorio:
#
#   1. la configuración activa de gcloud es de OTRA cuenta y otro proyecto,
#      y `gke-gcloud-auth-plugin` usa la cuenta ACTIVA para pedir el token;
#   2. `gke-gcloud-auth-plugin` no está en el PATH de una terminal nueva
#      (el cask de Homebrew no lo enlaza).
#
# Este script crea —o reutiliza— una configuración de gcloud propia
# (`sa-p9`), la activa, deja el plugin en el PATH vía ~/.zshrc, toma las
# credenciales del clúster y ejecuta el corrector con `p9.conf`.
#
# Para volver después a la configuración anterior:
#     gcloud config configurations activate <la-de-antes>
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

ANTERIOR="$(gcloud config configurations list --filter='is_active=true' --format='value(name)' 2>/dev/null)"
if ! gcloud config configurations describe sa-p9 >/dev/null 2>&1; then
  gcloud config configurations create sa-p9 --no-activate >/dev/null
fi
gcloud config configurations activate sa-p9 >/dev/null
env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT gcloud config set account "$CUENTA" >/dev/null 2>&1
env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT gcloud config set project "$PROJECT_ID" >/dev/null 2>&1
echo "✓ configuración de gcloud 'sa-p9' activa (cuenta ${CUENTA}, proyecto ${PROJECT_ID}); la anterior era '${ANTERIOR}'"

PLUGIN_DIR="$(dirname "$(command -v gke-gcloud-auth-plugin)")"
if ! grep -q "sa-p9: gke-gcloud-auth-plugin" "${HOME}/.zshrc" 2>/dev/null; then
  printf '\n# sa-p9: gke-gcloud-auth-plugin en el PATH (kubectl contra GKE)\nexport PATH="%s:$PATH"\nexport USE_GKE_GCLOUD_AUTH_PLUGIN=True\n' "$PLUGIN_DIR" >>"${HOME}/.zshrc"
  echo "✓ ${PLUGIN_DIR} añadido al PATH en ~/.zshrc (abre una terminal nueva)"
else
  echo "✓ el plugin ya estaba en el PATH de ~/.zshrc"
fi

env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT \
  gcloud container clusters get-credentials "$CLUSTER" --zone "$ZONE" --project "$PROJECT_ID" >/dev/null
echo "✓ contexto de kubectl: $(kubectl config current-context)"

# La prueba de fuego: kubectl SIN nuestras variables, como lo correrá el auxiliar.
if env -i HOME="$HOME" PATH="${PLUGIN_DIR}:/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin" \
     kubectl get ns >/dev/null 2>&1; then
  echo "✓ kubectl llega al clúster desde un entorno limpio"
else
  echo "✗ kubectl NO llega al clúster desde un entorno limpio" >&2; exit 1
fi
for t in git jq kubectl helm terraform velero argocd; do
  command -v "$t" >/dev/null || echo "⚠ falta '$t' (el corrector lo pide): brew install $t"
done

echo
echo "Ejecutando el corrector oficial desde ${DIR}:"
cd "$DIR"
env -u CLOUDSDK_CORE_ACCOUNT -u CLOUDSDK_CORE_PROJECT -u GOOGLE_OAUTH_ACCESS_TOKEN ./verificar_p9.sh
