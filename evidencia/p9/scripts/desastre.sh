#!/usr/bin/env bash
# ===========================================================================
# desastre.sh — Destruye el entorno, de golpe, como un desastre real.
#
#     P9/scripts/desastre.sh --confirmar sa-p9
#
# Qué destruye, y en este orden (campo «Escenario ejecutado» del informe):
#
#   1. el clúster de GKE entero —plano de control, los 3 nodos, todo lo que
#      corría dentro: ArgoCD, la plataforma, Velero, Kyverno, los Secret
#      descifrados, la llave de Sealed Secrets que vivía en kube-system—,
#      con `terraform destroy` de la capa `10-cluster`, SIN desmontar antes
#      nada de lo que corre dentro. No hay un apagado ordenado: así no se
#      pierden los clústeres de verdad;
#   2. el estado de la capa `20-gitops`, que describía objetos de un clúster
#      que ya no existe;
#   3. los DISCOS de los volúmenes (PostgreSQL y RabbitMQ de los dos
#      ambientes). GKE no los borra al borrar el clúster: quedarían huérfanos
#      y, peor, harían trampa —los datos «sobrevivirían» por accidente y la
#      restauración no probaría nada—. Se borran para que la ÚNICA vía de
#      recuperar los datos sea el respaldo de Velero.
#
# Qué NO destruye, a propósito: la fundación (`00-fundacion`): el bucket de
# respaldos, los snapshots, la llave en Secret Manager, la IP reservada y las
# cuentas de servicio. Es lo que un desastre del clúster no se lleva, y es
# exactamente lo que hace falta para salir de él.
# ===========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

[[ "${1:-}" == "--confirmar" && "${2:-}" == "$CLUSTER" ]] || {
  echo "Esto DESTRUYE el clúster ${CLUSTER} y los discos de sus volúmenes." >&2
  echo "Los datos solo se podrán recuperar desde los respaldos de Velero." >&2
  echo "  $0 --confirmar ${CLUSTER}" >&2
  exit 1
}

iniciar_registro desastre
marca "desastre" "inicio de la destrucción del entorno"

# --- Lo que hay ANTES: discos de los volúmenes y último respaldo -------------
DISCOS="$(mktemp)"
if cluster_existe && credenciales_cluster; then
  k get pv -o jsonpath='{range .items[*]}{.spec.csi.volumeHandle}{"\t"}{.spec.claimRef.namespace}/{.spec.claimRef.name}{"\n"}{end}' \
    2>/dev/null >"$DISCOS" || true
  marca "antes" "volúmenes persistentes: $(wc -l <"$DISCOS" | tr -d ' ')"
  sed 's/^/        /' "$DISCOS" | tee -a "$REGISTRO"
  ultimo=$(k -n "$NS_VELERO" get backups.velero.io -l "velero.io/schedule-name=${SCHEDULE_VELERO}" \
    -o jsonpath='{range .items[?(@.status.phase=="Completed")]}{.status.startTimestamp}{" "}{.metadata.name}{"\n"}{end}' 2>/dev/null | sort | tail -n 1)
  marca "antes" "último respaldo Completed: ${ultimo:-ninguno}"
else
  marca "antes" "el clúster no existe o no responde; se limpia lo que quede"
fi

# --- 1. El clúster -----------------------------------------------------------
T_DESTRUCCION="$(ahora_iso)"
export T_DESTRUCCION
marca "desastre" "DESASTRE: comienza la destrucción del clúster (T_destruccion=${T_DESTRUCCION})"
renovar_token
tf_init "$TF_CLUSTER" "$PREFIJO_CLUSTER"
ejecutar "desastre" "terraform destroy 10-cluster" -- \
  terraform -chdir="$TF_CLUSTER" destroy -input=false -auto-approve -no-color "${tf_vars_cluster[@]}"

# --- 2. El estado de la capa de GitOps -----------------------------------------
tf_init "$TF_GITOPS" "$PREFIJO_GITOPS"
recursos=$(terraform -chdir="$TF_GITOPS" state list 2>/dev/null || true)
if [[ -n "$recursos" ]]; then
  # shellcheck disable=SC2086
  terraform -chdir="$TF_GITOPS" state rm $recursos >/dev/null
  marca "desastre" "estado de 20-gitops vaciado ($(wc -l <<<"$recursos" | tr -d ' ') recursos del clúster destruido)"
fi

# --- 3. Los discos -------------------------------------------------------------
# Del inventario tomado antes; si el clúster ya no respondía, por la
# descripción que el driver CSI escribe en cada disco que crea.
if [[ ! -s "$DISCOS" ]]; then
  gcloud compute disks list --filter="zone:(${ZONE}) AND description~'sa-p8-(stage|prod)'" \
    --format='value(selfLink)' 2>/dev/null | awk '{print $1"\t?"}' >"$DISCOS" || true
fi
while IFS=$'\t' read -r disco pvc; do
  [[ -n "$disco" ]] || continue
  nombre="${disco##*/}"
  for _ in 1 2 3 4 5 6; do
    if gcloud compute disks delete "$nombre" --zone "$ZONE" --quiet >/dev/null 2>&1; then
      marca "desastre" "disco ${nombre} (${pvc}) BORRADO"
      break
    fi
    # Un disco recién desconectado de un nodo que se está borrando puede
    # seguir «en uso» unos segundos.
    sleep 10
  done
done <"$DISCOS"
rm -f "$DISCOS"

liberar_ip_huerfana

cluster_existe && fallar "el clúster sigue existiendo"
marca "desastre" "entorno destruido: no hay clúster, ni discos de datos; la fundación sigue en pie"
marca "fundacion" "respaldos: $(gcloud storage ls "gs://${BUCKET_VELERO}/backups/" 2>/dev/null | wc -l | tr -d ' ') en gs://${BUCKET_VELERO}"
