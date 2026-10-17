#!/usr/bin/env bash
# ===========================================================================
# prueba-dr.sh — La prueba de recuperación cronometrada (§3.2).
#
#     P9/scripts/prueba-dr.sh --confirmar sa-p9 [--espera-min 4]
#
# Destruye el entorno entero y lo reconstruye con el punto de entrada único,
# midiendo desde fuera cuánto tiempo estuvo caído (RTO) y desde dentro de la
# base cuántas escrituras confirmadas se perdieron (RPO).
#
#   1. Carga continua de datos: una marca cada 10 s en `ops_db.p9_marcas`,
#      guardando en local qué se escribió y cuándo. La base ya tiene además
#      los latidos del CronJob de la plataforma (`heartbeats`, cada 2 min).
#   2. Sonda contra la URL pública cada 5 s, durante TODA la prueba.
#   3. Espera a que el Schedule complete un respaldo con marcas dentro, y
#      sigue escribiendo `--espera-min` minutos más. El desastre NO se
#      alinea con el respaldo: llega cuando llega, y lo escrito desde el
#      último respaldo se pierde de verdad.
#   4. `desastre.sh`   — clúster y discos destruidos.
#   5. `bootstrap.sh`  — reconstrucción, sin intervención.
#   6. Medición: huella de la base antes/después, marcas perdidas, RTO y RPO
#      frente a lo declarado (`analisis/medir.py`).
#
# Un solo registro con todo: `P9/docs/evidencias/prueba-dr-<UTC>.log`, más
# los archivos de datos al lado (`prueba-dr-<UTC>/`).
# ===========================================================================
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=config.sh
source "$DIR/config.sh"
# shellcheck source=lib.sh
source "$DIR/lib.sh"

[[ "${1:-}" == "--confirmar" && "${2:-}" == "$CLUSTER" ]] || {
  echo "Esto DESTRUYE el clúster ${CLUSTER} y lo reconstruye midiendo RTO y RPO." >&2
  echo "  $0 --confirmar ${CLUSTER} [--espera-min N]" >&2
  exit 1
}
ESPERA_MIN=4
[[ "${3:-}" == "--espera-min" ]] && ESPERA_MIN="${4:?}"

RTO_DECLARADO_MIN=40
RPO_DECLARADO_MIN=15

iniciar_registro prueba-dr
DATOS="${REGISTRO%.log}"
mkdir -p "$DATOS"
marca "prueba" "prueba de DR cronometrada · RTO declarado ${RTO_DECLARADO_MIN} min · RPO declarado ${RPO_DECLARADO_MIN} min"

# --- 0. Punto de partida sano ------------------------------------------------
credenciales_cluster || fallar "no hay clúster: la prueba parte de un sistema operativo"
apps_sanas || { estado_apps | tee -a "$REGISTRO"; fallar "no todas las Application están Synced/Healthy"; }
[[ -n "$(ultimo_respaldo)" ]] || fallar "no hay ningún respaldo Completed todavía"
marca "antes" "sistema sano; último respaldo: $(ultimo_respaldo)"

crear_tabla_marcas >/dev/null
huella_bd >"$DATOS/huella-antes.txt"
marca "antes" "huella de la base: $(wc -l <"$DATOS/huella-antes.txt" | tr -d ' ') tablas → $(basename "$DATOS")/huella-antes.txt"

# --- 1 y 2. Escritor y sonda ---------------------------------------------------
ESCRITAS="$DATOS/marcas-escritas.txt"; : >"$ESCRITAS"
(
  while [[ ! -f "$DATOS/parar-escritor" ]]; do
    insertar_marca prueba-dr >>"$ESCRITAS" 2>/dev/null || true
    sleep 10
  done
) &
PID_ESCRITOR=$!
sonda_iniciar "$DATOS/sonda.txt" /health 5
trap 'touch "$DATOS/parar-escritor"; sonda_parar "$DATOS/sonda.txt"' EXIT
marca "carga" "escritor (1 marca/10 s) y sonda (GET /health cada 5 s) en marcha"

# --- 3. Un respaldo con marcas dentro, y después el azar ----------------------
previo="$(ultimo_respaldo)"
marca "carga" "esperando al siguiente respaldo programado (≤ 15 min)…"
limite=$(( $(ahora_epoch) + 20 * 60 ))
until [[ "$(ultimo_respaldo)" != "$previo" ]]; do
  (( $(ahora_epoch) < limite )) || fallar "el Schedule no completó un respaldo en 20 min"
  sleep 20
done
marca "carga" "respaldo completado: $(ultimo_respaldo); se sigue escribiendo ${ESPERA_MIN} min"
sleep $(( ESPERA_MIN * 60 ))

touch "$DATOS/parar-escritor"; wait "$PID_ESCRITOR" 2>/dev/null || true
marca "carga" "escritor detenido: $(wc -l <"$ESCRITAS" | tr -d ' ') marcas escritas; última: $(tail -n 1 "$ESCRITAS" | cut -d'|' -f2)"

# --- 4. Desastre ---------------------------------------------------------------
T_DESASTRE="$(ahora_iso)"
marca "desastre" "═══ T_desastre = ${T_DESASTRE} ═══"
"$DIR/desastre.sh" --confirmar "$CLUSTER"

# --- 5. Reconstrucción -----------------------------------------------------------
marca "recuperacion" "═══ reconstrucción con el punto de entrada único ═══"
"$DIR/bootstrap.sh"

# Unos segundos más de sonda tras el primer 200, para que se vea estable.
sleep 30
sonda_parar "$DATOS/sonda.txt"; trap - EXIT

# --- 6. Medición -----------------------------------------------------------------
credenciales_cluster
psql_bd ops_db <<'SQL' >"$DATOS/marcas-recuperadas.txt"
SELECT id, to_char(creado AT TIME ZONE 'UTC', 'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'), contenido
FROM p9_marcas WHERE origen = 'prueba-dr' ORDER BY id;
SQL
huella_bd >"$DATOS/huella-despues.txt"
RESPALDO_INICIO=$(k -n "$NS_VELERO" get configmap "$CM_RESULTADO_RESTAURACION" -o jsonpath='{.data.respaldo_inicio}' 2>/dev/null || true)

{
  echo
  echo "════════════════════════════════════════════════════════════════════"
  echo " MEDICIÓN"
  echo "════════════════════════════════════════════════════════════════════"
  sonda_resumen "$DATOS/sonda.txt"
  echo
  python3 "$DIR/analisis/medir.py" \
    --escritas "$DATOS/marcas-escritas.txt" \
    --recuperadas "$DATOS/marcas-recuperadas.txt" \
    --sonda "$DATOS/sonda.txt" \
    --desastre "$T_DESASTRE" \
    ${RESPALDO_INICIO:+--respaldo "$RESPALDO_INICIO"} \
    --huella-antes "$DATOS/huella-antes.txt" \
    --huella-despues "$DATOS/huella-despues.txt" \
    --rto-declarado-min "$RTO_DECLARADO_MIN" \
    --rpo-declarado-min "$RPO_DECLARADO_MIN"
} | tee -a "$REGISTRO"

marca "prueba" "verificación completa del sistema reconstruido"
"$DIR/verificar.sh" | tee -a "$REGISTRO" || true
marca "fin" "prueba de DR terminada → ${REGISTRO#"${RAIZ}/"}"
