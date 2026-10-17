#!/usr/bin/env bash
# ===========================================================================
# configurar-gitops.sh — Configuración ÚNICA del repositorio GitOps.
#
#     P9/scripts/configurar-gitops.sh             # IP + llave + resellar
#     P9/scripts/configurar-gitops.sh --solo-ip   # solo la IP y el certificado
#
# NO es parte de la recuperación: se ejecuta UNA vez, después del primer
# `terraform apply` de la fundación, y deja en el repositorio GitOps lo que
# solo se conoce entonces. Como la fundación sobrevive a los desastres, nada
# de esto cambia al reconstruir, y `bootstrap.sh` no lo necesita nunca más.
#
#   1. la IP reservada → `loadBalancerIP` de ingress-nginx y los hosts
#      `sa-p9[-stage].<ip>.nip.io` de los dos ambientes;
#   2. el certificado PÚBLICO de la llave de Sealed Secrets →
#      `sealed-secrets/clave-publica.pem`;
#   3. los 16 SealedSecret, sellados de nuevo con esa llave y con
#      credenciales recién generadas.
#
# ## Por qué volver a sellar
#
# Los SealedSecret de la P8 se sellaron con la llave que generó el
# controlador DENTRO del clúster kind: la que la P9 existe para no depender
# de ella. La llave nueva nace en Terraform y vive en Secret Manager; lo
# sellado con la vieja no se puede abrir con la nueva.
#
# El sellado es SIN CONEXIÓN (`kubeseal --cert`): no hace falta un clúster,
# solo el certificado público. Las credenciales en claro existen unos
# segundos en un archivo temporal y se borran.
#
# ## Cuándo NO volver a ejecutarlo
#
# Con datos ya respaldados. Las contraseñas de PostgreSQL viven DENTRO del
# volumen (las fija `initdb` la primera vez); si se sellan contraseñas
# nuevas, la base restaurada no las reconocerá y los servicios no podrán
# conectarse. El script se niega si el bucket ya tiene respaldos, salvo con
# `--forzar`.
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR/config.sh"
source "$DIR/lib.sh"

SOLO_IP=0; FORZAR=0
for a in "$@"; do
  case "$a" in
    --solo-ip) SOLO_IP=1 ;;
    --forzar) FORZAR=1 ;;
    *) echo "uso: $0 [--solo-ip] [--forzar]" >&2; exit 1 ;;
  esac
done

[[ -d "${GITOPS_DIR}/.git" ]] || { echo "ERROR: no está el repositorio GitOps en ${GITOPS_DIR} (GITOPS_DIR=...)" >&2; exit 1; }

# IP_FORZADA y CERT_FORZADO existen para probar el sellado sin la fundación.
if [[ -z "${IP_FORZADA:-}" || -z "${CERT_FORZADO:-}" ]]; then
  renovar_token
  tf_init "$TF_FUNDACION" "$PREFIJO_FUNDACION"
fi
IP="${IP_FORZADA:-$(tf_salida "$TF_FUNDACION" ip_ingress)}"
CERT="$(mktemp)"; VALORES="$(mktemp)"; PLANOS="$(mktemp)"
trap 'rm -f "$CERT" "$VALORES" "$PLANOS"' EXIT
if [[ -n "${CERT_FORZADO:-}" ]]; then cp "$CERT_FORZADO" "$CERT"; else
  terraform -chdir="$TF_FUNDACION" output -raw certificado_sealed_secrets >"$CERT"; fi
[[ "$IP" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "ERROR: IP inválida: '$IP'" >&2; exit 1; }
openssl x509 -noout -in "$CERT" || { echo "ERROR: el certificado no es válido" >&2; exit 1; }

# --- 1. IP -------------------------------------------------------------------------
# Sustituye tanto el marcador como una IP anterior: el script es idempotente.
python3 - "$GITOPS_DIR" "$IP" <<'PY'
import pathlib, re, sys
raiz, ip = pathlib.Path(sys.argv[1]), sys.argv[2]
ipre = r"(?:IP_RESERVADA|\d+\.\d+\.\d+\.\d+)"
for rel in ["apps/03-ingress-nginx.yaml", "envs/prod/values.yaml", "envs/stage/values.yaml"]:
    p = raiz / rel
    s = p.read_text()
    n = re.sub(r'(loadBalancerIP: ")' + ipre + '"', r'\g<1>' + ip + '"', s)
    n = re.sub(r"(sa-p9(?:-stage)?\.)" + ipre + r"(\.nip\.io)", r"\g<1>" + ip + r"\g<2>", n)
    if n != s:
        p.write_text(n)
        print(f"  · {rel}")
PY
echo "✓ IP ${IP} escrita (hosts: sa-p9.${IP}.nip.io, sa-p9-stage.${IP}.nip.io)"

# --- 2. Certificado público ------------------------------------------------------------
mkdir -p "${GITOPS_DIR}/sealed-secrets"
cp "$CERT" "${GITOPS_DIR}/sealed-secrets/clave-publica.pem"
echo "✓ certificado: $(openssl x509 -noout -fingerprint -sha256 -in "$CERT" | cut -d= -f2)"

(( SOLO_IP )) && { git -C "$GITOPS_DIR" status --short; exit 0; }

# --- 3. Volver a sellar ------------------------------------------------------------------
if (( ! FORZAR )) && gcloud storage ls "gs://${BUCKET_VELERO}/backups/" 2>/dev/null | grep -q .; then
  echo "ERROR: ya hay respaldos en gs://${BUCKET_VELERO}. Resellar cambiaría las contraseñas" >&2
  echo "  y la base restaurada no las aceptaría. Usa --solo-ip, o --forzar si sabes lo que haces." >&2
  exit 1
fi

gen() { openssl rand -base64 48 | tr -d '=+/\n' | cut -c1-32; }
for amb in stage prod; do
  ns="sa-p8-${amb}"
  cat >"$VALORES" <<YAML
secrets:
  create: true
  postgresAdminPassword: "$(gen)"
  databasePasswords:
    auth_db: "$(gen)"
    catalog_db: "$(gen)"
    order_db: "$(gen)"
    notification_db: "$(gen)"
    ops_db: "$(gen)"
  rabbitmqPassword: "$(gen)"
  rabbitmqErlangCookie: "$(gen)"
  jwtSecretKey: "$(gen)"
  aesSecretKey: "$(gen)"
  hmacSecretKey: "$(gen)"
  seedAdminPassword: "$(gen)"
YAML
  helm template sa-platform "${GITOPS_DIR}/charts/sa-platform" -n "$ns" \
    -s templates/secrets.yaml \
    -f "${GITOPS_DIR}/envs/comunes.yaml" -f "${GITOPS_DIR}/envs/${amb}/values.yaml" \
    -f "$VALORES" --set secrets.create=true >"$PLANOS"
  : >"$VALORES"
  python3 - "$PLANOS" "${GITOPS_DIR}/sealed-secrets/${amb}" "$CERT" <<'PY'
import pathlib, re, subprocess, sys
planos, destino, cert = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
destino.mkdir(parents=True, exist_ok=True)
for viejo in destino.glob("*.yaml"):
    viejo.unlink()
docs = [d for d in planos.read_text().split("\n---\n") if re.search(r"^kind: Secret$", d, re.M)]
for d in docs:
    nombre = re.search(r"^  name: (\S+)", d, re.M).group(1)
    sellado = subprocess.run(["kubeseal", "--format", "yaml", "--cert", cert],
                             input=d, capture_output=True, text=True, check=True).stdout
    (destino / f"{nombre}.yaml").write_text(sellado)
print(f"  · {destino.name}: {len(docs)} SealedSecret")
PY
  : >"$PLANOS"
done
echo "✓ secretos sellados de nuevo con la llave de Secret Manager"
echo
git -C "$GITOPS_DIR" status --short
echo
echo "Siguiente paso: revisar, commitear y llevar a 'main' el repositorio GitOps"
echo "  git -C ${GITOPS_DIR} add -A && git -C ${GITOPS_DIR} commit -m 'p9: IP reservada y secretos sellados con la llave de Secret Manager'"
