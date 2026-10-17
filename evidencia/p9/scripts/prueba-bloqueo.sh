#!/usr/bin/env bash
# ===========================================================================
# prueba-bloqueo.sh — El estado remoto SÍ bloquea (§3.3, criterio 2.2).
#
#     P9/scripts/prueba-bloqueo.sh
#
# Lanza un `terraform plan` sobre la fundación y, mientras corre, un segundo
# `plan` con `-lock-timeout=0s`. El segundo tiene que fallar con «Error
# acquiring the state lock» y decir QUIÉN tiene el candado. Entre los dos, se
# lista el bucket de estado para ver el objeto `default.tflock`.
#
# También deja constancia de lo que el §8.1 exige: que no hay ningún archivo
# de estado en el repositorio, ni en el árbol ni en la historia de Git.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
source "$DIR/lib.sh"

iniciar_registro bloqueo-estado
renovar_token
tf_init "$TF_FUNDACION" "$PREFIJO_FUNDACION"

marca "estado" "backend: gcs · bucket gs://${BUCKET_TFSTATE} · prefijos ${PREFIJO_FUNDACION}/ ${PREFIJO_CLUSTER}/ ${PREFIJO_GITOPS}/"
ejecutar "estado" "contenido del bucket de estado" -- gcloud storage ls -l "gs://${BUCKET_TFSTATE}/**"
ejecutar "estado" "versionado del bucket de estado" -- \
  gcloud storage buckets describe "gs://${BUCKET_TFSTATE}" --format='value(versioning_enabled,public_access_prevention,uniform_bucket_level_access)'

A="$(mktemp)"; B="$(mktemp)"; trap 'rm -f "$A" "$B"' EXIT
marca "bloqueo" "plan A: toma el candado del estado de la fundación"
terraform -chdir="$TF_FUNDACION" plan -input=false -no-color -lock=true "${tf_vars_fundacion[@]}" >"$A" 2>&1 &
PA=$!

for _ in $(seq 1 40); do
  gcloud storage ls "gs://${BUCKET_TFSTATE}/${PREFIJO_FUNDACION}/default.tflock" >/dev/null 2>&1 && break
  sleep 0.5
done
ejecutar "bloqueo" "el candado existe mientras A trabaja" -- \
  gcloud storage cat "gs://${BUCKET_TFSTATE}/${PREFIJO_FUNDACION}/default.tflock"

marca "bloqueo" "plan B: intenta lo mismo, sin esperar (-lock-timeout=0s)"
if terraform -chdir="$TF_FUNDACION" plan -input=false -no-color -lock=true -lock-timeout=0s "${tf_vars_fundacion[@]}" >"$B" 2>&1; then
  marca "bloqueo" "✗ B NO fue bloqueado (A terminó antes; repetir la prueba)"
else
  marca "bloqueo" "✓ B fue rechazado por el candado:"
  sed -n '/Error acquiring the state lock/,/^$/p;/Lock Info/,/^$/p' "$B" | sed 's/^/        /' | tee -a "$REGISTRO"
fi
wait "$PA" || true
marca "bloqueo" "A terminó: $(grep -E '^(No changes|Plan:)' "$A" | head -n1)"
gcloud storage ls "gs://${BUCKET_TFSTATE}/${PREFIJO_FUNDACION}/default.tflock" >/dev/null 2>&1 \
  && marca "bloqueo" "✗ el candado sigue puesto" || marca "bloqueo" "✓ el candado se liberó al terminar A"

marca "repositorio" "archivos de estado en el árbol: $(git -C "$RAIZ" ls-files | grep -cE '\.tfstate(\.backup)?$' || true)"
marca "repositorio" "archivos de estado en TODA la historia: $(git -C "$RAIZ" log --all --format= --name-only | grep -cE '\.tfstate(\.backup)?$' || true)"
# (El patrón va partido en dos para que este mismo archivo no se cuente.)
marca "repositorio" "credenciales en el repositorio (llaves JSON de cuenta de servicio): $(git -C "$RAIZ" grep -l '"private_key''_id"' -- P9 2>/dev/null | wc -l | tr -d ' ')"
