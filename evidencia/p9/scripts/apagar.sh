#!/usr/bin/env bash
# ===========================================================================
# apagar.sh — Apagar el entorno al terminar una sesión, sin perder datos.
#
#     P9/scripts/apagar.sh
#
# Para no pagar el clúster cuando nadie lo usa (~$0.45/h). Es la misma
# destrucción que la prueba de DR (`desastre.sh`), con una diferencia: ANTES
# toma un respaldo de Velero en ese instante. Así lo escrito durante la sesión
# no se pierde, y `encender.sh` lo restaura.
#
# Queda en pie la fundación (bucket de respaldos, snapshots, llave en Secret
# Manager, IP reservada): ~$0.30/día.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

iniciar_registro apagado
marca "apagado" "apagar el entorno al final de la sesión"

if cluster_existe && credenciales_cluster; then
  # El respaldo final. Lleva la etiqueta del Schedule (`--from-schedule`), así
  # que el Job de restauración de `encender.sh` lo elige como el más reciente.
  # GCP admite un snapshot por disco cada 10 min: si el Schedule acaba de
  # tomar uno, el respaldo puede fallar por frecuencia; se reintenta.
  for intento in 1 2; do
    nombre="apagado-$(date -u +%Y%m%d-%H%M%S)"
    velero --kubecontext "$KUBE_CONTEXT" backup create "$nombre" \
      --from-schedule "$SCHEDULE_VELERO" --wait >/dev/null 2>&1 || true
    fase=$(k -n "$NS_VELERO" get backups.velero.io "$nombre" -o jsonpath='{.status.phase}' 2>/dev/null || true)
    marca "respaldo" "respaldo final ${nombre}: ${fase:-sin estado}"
    [[ "$fase" == "Completed" ]] && break
    if (( intento == 1 )); then
      marca "respaldo" "se reintenta en 10 min (límite de un snapshot por disco cada 10 min)"
      sleep 600
    else
      fallar "no se pudo tomar el respaldo final; NO se apaga para no perder datos (velero backup describe ${nombre})"
    fi
  done
else
  marca "apagado" "no hay clúster: solo se limpia lo que haya quedado"
fi

"$DIR/desastre.sh" --confirmar "$CLUSTER"
marca "apagado" "entorno apagado. Para volver: P9/scripts/encender.sh"
