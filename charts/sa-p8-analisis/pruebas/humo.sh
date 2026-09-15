#!/bin/sh
# ===========================================================================
# humo.sh — ¿Está viva la versión candidata?
#
# La primera y más barata de las tres puertas. Corre en segundos y responde
# una sola pregunta: ¿el binario nuevo arranca y contesta?
#
# ## Contra quién corre
#
# Contra `$SERVICIO_CANARY`, que es el Service que apunta EXCLUSIVAMENTE a los
# pods de la versión nueva. No contra el Ingress ni contra el Service estable:
# por ahí llegaría una mezcla de las dos versiones y, con el canary al 10 %,
# nueve de cada diez peticiones medirían la versión vieja. Una prueba así
# pasaría siempre.
#
# ## Por qué no basta con la readiness probe
#
# La readiness del gateway (`/health/ready`) responde en cuanto el proceso
# acepta conexiones: no consulta a nadie, y es correcto que así sea —ver el
# comentario en `P5/gateway/src/index.ts`—. Eso significa que un pod puede
# estar `Ready` y aun así devolver 500 en toda ruta real. Esta prueba mira las
# rutas reales.
#
# ## Criterio de aceptación
#
# Binario: CUALQUIER comprobación que falle termina el script con código
# distinto de cero, el Job falla, y con `failureLimit: 0` en la plantilla de
# análisis eso aborta el rollout de inmediato.
#
# No hay umbral que ajustar aquí a propósito. «El 90 % de los endpoints
# responde» no es un estado aceptable para una versión que está a punto de
# recibir tráfico de usuarios; es un estado roto con buena presentación.
# ===========================================================================
set -eu

BASE="http://${SERVICIO_CANARY}.${NAMESPACE}.svc.cluster.local:${PUERTO}"
FALLOS=0

echo "── Prueba de humo contra ${BASE}"
echo

# ---------------------------------------------------------------------------
# comprobar <descripción> <ruta> <código esperado> [fragmento que debe aparecer]
#
# Una función y no diez bloques repetidos: así el formato de la salida es el
# mismo en todas, y cuando el análisis falla el registro del Job dice qué
# comprobación cayó sin tener que cruzarlo con el código.
# ---------------------------------------------------------------------------
comprobar() {
  descripcion="$1"
  ruta="$2"
  esperado="$3"
  fragmento="${4:-}"

  cuerpo=$(mktemp)
  # `--max-time 10`: sin límite, un gateway colgado dejaría a curl esperando
  # hasta el `activeDeadlineSeconds` del Job y el análisis tardaría minutos en
  # declarar un fallo que ya era evidente.
  codigo=$(curl -s -o "$cuerpo" -w '%{http_code}' --max-time 10 "${BASE}${ruta}" || echo "000")

  if [ "$codigo" != "$esperado" ]; then
    printf '  ✗ %-46s HTTP %s (esperado %s)\n' "$descripcion" "$codigo" "$esperado"
    FALLOS=$((FALLOS + 1))
    rm -f "$cuerpo"
    return
  fi

  if [ -n "$fragmento" ] && ! grep -q "$fragmento" "$cuerpo"; then
    printf '  ✗ %-46s HTTP %s pero falta «%s»\n' "$descripcion" "$codigo" "$fragmento"
    echo "      cuerpo: $(head -c 200 "$cuerpo")"
    FALLOS=$((FALLOS + 1))
    rm -f "$cuerpo"
    return
  fi

  printf '  ✓ %-46s HTTP %s\n' "$descripcion" "$codigo"
  rm -f "$cuerpo"
}

# --- Las sondas del propio gateway ----------------------------------------
comprobar "liveness del gateway"          "/health/self"    200 '"status":"ok"'
comprobar "readiness del gateway"         "/health/ready"   200 '"status":"ok"'

# --- La salud agregada -----------------------------------------------------
#
# Es la comprobación que más cubre: una sola petición aquí provoca cuatro
# salientes en paralelo a auth, catalog, order y notification. Si la versión
# nueva rompió el cliente HTTP, la resolución de nombres o la configuración de
# las URL de los upstreams, se ve aquí y no en las sondas de arriba.
#
# 200 exactamente: el gateway responde 503 cuando algún upstream está caído.
comprobar "salud agregada de los 4 servicios" "/health"     200 '"status":"ok"'

# --- El mapa de la API -----------------------------------------------------
#
# `GET /` enumera las rutas montadas. Que responda demuestra que el arranque
# llegó hasta el registro de rutas, que es lo último que hace el gateway antes
# de escuchar.
comprobar "mapa de la API"                "/"               200 '/api/auth'

# --- Rutas que deben seguir CERRADAS ---------------------------------------
#
# Una prueba de humo que solo comprueba que las cosas responden deja pasar la
# regresión más peligrosa: la que abre lo que estaba cerrado. Estas dos rutas
# tienen que seguir rechazando.
#
# `/api/auth/introspect` es la conversación privada entre el gateway y
# auth-service; exponerla dejaría comprobar tokens ajenos desde fuera.
comprobar "introspect sigue cerrada"      "/api/auth/introspect" 404
# `/api/orders` exige sesión. Sin cookie tiene que ser 401, no 200 ni 500.
comprobar "pedidos exigen sesión"         "/api/orders"     401

echo
if [ "$FALLOS" -gt 0 ]; then
  echo "── HUMO: ${FALLOS} comprobación(es) fallida(s) — se aborta el rollout"
  exit 1
fi
echo "── HUMO: todo correcto"
