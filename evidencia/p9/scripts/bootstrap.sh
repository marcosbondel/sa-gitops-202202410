#!/usr/bin/env bash
# ===========================================================================
# bootstrap.sh — EL punto de entrada único de la reconstrucción (§3.2, 2.1).
#
#     P9/scripts/bootstrap.sh
#
# Una orden, ninguna pregunta, ninguna intervención humana. Sirve igual
# para el primer arranque que para recuperarse de la pérdida total del
# clúster: cada paso es idempotente y averigua solo en qué caso está.
#
#   1. facturación y bucket de estado     (gcloud; el bucket no puede ser
#                                          de Terraform, ver versions.tf)
#   2. 00-fundacion    terraform apply    (normalmente: sin cambios)
#   3. IP pública      liberar la regla de reenvío huérfana, si la hay
#   4. 10-cluster      terraform apply    GKE + pool de 3 nodos
#   5. 20-gitops       terraform apply    llave de Sealed Secrets → ArgoCD
#                                         → Application raíz `sa-p9-raiz`
#   6. ArgoCD          app-of-apps, ola por ola:
#                        -40 complementos (Velero, Kyverno, Rollouts, …)
#                        -30 namespaces · -20 políticas
#                        -15 RESTAURACIÓN de volúmenes desde Velero
#                        -10 secretos · -5 análisis · 0 plataforma
#                         10 Schedule de respaldos
#   7. verificación    el servicio responde por la IP pública, con datos
#
# El registro completo queda en `P9/docs/evidencias/reconstruccion-<UTC>.log`, con marcas de
# tiempo. El RTO de la reconstrucción es la diferencia entre la primera y la
# última línea.
# ===========================================================================
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/config.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TIMEOUT_APPS_MIN="${TIMEOUT_APPS_MIN:-45}"

iniciar_registro reconstruccion
marca "inicio" "bootstrap: reconstrucción desde cero (punto de entrada único)"
T_BOOT="$(ahora_epoch)"

# --- 1. Facturación y bucket de estado ---------------------------------------
[[ "$(gcloud billing projects describe "$PROJECT_ID" --format='value(billingEnabled)' 2>/dev/null)" == "True" ]] \
  || fallar "el proyecto ${PROJECT_ID} no tiene facturación habilitada (runbook §0)"
marca "estado" "facturación habilitada en ${PROJECT_ID}"

gcloud services enable storage.googleapis.com >/dev/null
if ! gcloud storage buckets describe "gs://${BUCKET_TFSTATE}" >/dev/null 2>&1; then
  ejecutar "estado" "crear gs://${BUCKET_TFSTATE} (versionado, sin acceso público)" -- \
    gcloud storage buckets create "gs://${BUCKET_TFSTATE}" --location=US \
      --uniform-bucket-level-access --public-access-prevention
  gcloud storage buckets update "gs://${BUCKET_TFSTATE}" --versioning >/dev/null
else
  marca "estado" "gs://${BUCKET_TFSTATE} ya existe (estado remoto con bloqueo)"
fi

# --- 2. Fundación ------------------------------------------------------------
renovar_token
tf_init "$TF_FUNDACION" "$PREFIJO_FUNDACION"
ejecutar "fundacion" "terraform apply 00-fundacion" -- \
  terraform -chdir="$TF_FUNDACION" apply -input=false -auto-approve -no-color "${tf_vars_fundacion[@]}"

# El repositorio GitOps tiene que conocer la IP reservada. Es configuración
# de UNA sola vez (`configurar-gitops.sh`), no parte de la recuperación; si
# falta, se avisa ahora y no a los 20 minutos con un Service en <pending>.
ingress_git=$(curl -fsSL "https://raw.githubusercontent.com/marcosbondel/sa-gitops-202202410/${GITOPS_RAMA}/apps/03-ingress-nginx.yaml" 2>/dev/null || true)
if [[ -z "$ingress_git" ]] || grep -q 'IP_RESERVADA' <<<"$ingress_git"; then
  fallar "el repositorio GitOps (rama ${GITOPS_RAMA}) aún no tiene la IP reservada: ejecuta P9/scripts/configurar-gitops.sh una vez y lleva el cambio a ${GITOPS_RAMA}"
fi

# --- 3. IP pública -----------------------------------------------------------
if ! cluster_existe; then
  liberar_ip_huerfana
fi
marca "ip" "IP pública reservada: $(ip_publica)"

# --- 4. Clúster --------------------------------------------------------------
renovar_token
tf_init "$TF_CLUSTER" "$PREFIJO_CLUSTER"
ejecutar "cluster" "terraform apply 10-cluster (GKE, ${NUM_NODES} × ${MACHINE_TYPE})" -- \
  terraform -chdir="$TF_CLUSTER" apply -input=false -auto-approve -no-color "${tf_vars_cluster[@]}"
credenciales_cluster
marca "cluster" "nodos: $(k get nodes --no-headers 2>/dev/null | awk '{print $1" "$2}' | paste -sd ',' -)"

# --- 5. Arranque de GitOps ---------------------------------------------------
renovar_token
tf_init "$TF_GITOPS" "$PREFIJO_GITOPS"
ejecutar "gitops" "terraform apply 20-gitops (llave → ArgoCD → sa-p9-raiz)" -- \
  terraform -chdir="$TF_GITOPS" apply -input=false -auto-approve -no-color "${tf_vars_gitops[@]}"

# --- 6. ArgoCD levanta el resto ----------------------------------------------
# Se registra cada CAMBIO de estado de cada Application, con su hora: el
# registro muestra el orden real de las olas, que es la evidencia de que el
# diagrama del bootstrap describe lo que pasa y no lo que se quería que pasara.
marca "argocd" "app-of-apps en marcha; esperando a que todas estén Synced/Healthy (máx. ${TIMEOUT_APPS_MIN} min)"
# (Bash 3.2 —el de macOS— no tiene arreglos asociativos: el estado anterior
# se guarda en un archivo y se compara línea a línea.)
ANTES="$(mktemp)"; AHORA="$(mktemp)"
trap 'rm -f "$ANTES" "$AHORA"' EXIT
limite=$(( $(ahora_epoch) + TIMEOUT_APPS_MIN * 60 ))
until apps_sanas; do
  (( $(ahora_epoch) < limite )) || { estado_apps | tee -a "$REGISTRO"; fallar "las Application no quedaron sanas en ${TIMEOUT_APPS_MIN} min (runbook §6)"; }
  estado_apps | tail -n +2 | sort >"$AHORA"
  while read -r app ola sync salud; do
    [[ -n "$app" ]] || continue
    marca "argocd" "$(printf '%-26s ola %4s  %s / %s' "$app" "$ola" "$sync" "$salud")"
  done < <(comm -13 "$ANTES" "$AHORA")
  cp "$AHORA" "$ANTES"
  sleep 10
done
marca "argocd" "todas las Application Synced/Healthy"
estado_apps | sed 's/^/        /' | tee -a "$REGISTRO"

# --- 7. Verificación ---------------------------------------------------------
r=$(k -n "$NS_VELERO" get configmap "$CM_RESULTADO_RESTAURACION" -o jsonpath='{.data.estado} — {.data.detalle} · respaldo {.data.respaldo} (inicio {.data.respaldo_inicio})' 2>/dev/null || echo "sin resultado")
marca "datos" "restauración: $r"

HOST="$(host_prod)"; IP="$(ip_publica)"
marca "servicio" "esperando 200 en http://${HOST}/health"
limite=$(( $(ahora_epoch) + 600 ))
until [[ "$(curl -s -o /dev/null -w '%{http_code}' -m 5 -H "Host: ${HOST}" "http://${IP}/health")" == "200" ]]; do
  (( $(ahora_epoch) < limite )) || fallar "el servicio no respondió 200 en 10 min"
  sleep 5
done
marca "servicio" "http://${HOST}/health → 200"

s=$(( $(ahora_epoch) - T_BOOT ))
marca "fin" "$(printf 'sistema reconstruido y respondiendo en %d min %02d s' $((s / 60)) $((s % 60)))"

{
  echo
  echo "## Resumen de la infraestructura"
  terraform -chdir="$TF_FUNDACION" output -raw resumen 2>/dev/null
  terraform -chdir="$TF_CLUSTER" output -raw resumen 2>/dev/null
} | tee -a "$REGISTRO"

echo
echo "Registro: ${REGISTRO#"${RAIZ}/"}"
echo "ArgoCD:   kubectl -n argocd port-forward svc/argocd-server 8080:80   →  http://localhost:8080"
echo "          usuario admin · contraseña: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
echo "Sistema:  http://${HOST}/"
