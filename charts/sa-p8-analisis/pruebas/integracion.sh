#!/bin/sh
# ===========================================================================
# integracion.sh — ¿Funciona un flujo completo de usuario en la versión nueva?
#
# La segunda puerta. La de humo comprueba que los endpoints responden; esta
# comprueba que hacen su trabajo, recorriendo de punta a punta el camino que
# atraviesa los cuatro microservicios, PostgreSQL y RabbitMQ:
#
#     registro → sesión → identidad → catálogo (GraphQL) → pedidos → bandeja
#
# ## Por qué un cookie jar y no una cabecera `Authorization`
#
# `auth-service` NO devuelve el JWT en el cuerpo: lo deja en una cookie
# HTTP-only, a propósito, para que un frontend no pueda leerlo desde
# JavaScript (ver `P5/services/auth-service/app/schemas/auth.py`). Una prueba
# que intentara extraer el token del JSON leería `null` y todo lo demás daría
# 401. Se usa `-c`/`-b` con un archivo temporal, que es lo que hace un
# navegador.
#
# ## Por qué cada ejecución crea un usuario nuevo
#
# El correo lleva el nombre del pod y la marca de tiempo. Si fuera fijo, la
# segunda ejecución del análisis chocaría con un 409 «email ya registrado» y
# la prueba fallaría por haber pasado antes. Con el canary ejecutando esta
# plantilla cada 45 segundos durante nueve minutos, eso sería un fallo
# garantizado en el segundo intento.
#
# ## Criterio de aceptación
#
# Binario, igual que el humo. Un flujo de compra que funciona «casi siempre»
# no es un flujo de compra que funciona.
# ===========================================================================
set -eu

BASE="http://${SERVICIO_CANARY}.${NAMESPACE}.svc.cluster.local:${PUERTO}"
GALLETAS=$(mktemp)
CUERPO=$(mktemp)
FALLOS=0

# Identidad única por ejecución.
#
# `HOSTNAME` es el nombre del pod del Job, que Kubernetes garantiza distinto en
# cada intento; se recortan los últimos caracteres porque el nombre completo de
# un pod de AnalysisRun pasa de sesenta y deja un correo ilegible en los
# registros.
#
# ## El dominio NO puede ser `.test`
#
# La primera versión usaba `@sa-p8.test` —el TLD que la RFC 2606 reserva
# justamente para pruebas— y auth-service la rechazó con un 422:
#
#     value is not a valid email address: The part after the @-sign is a
#     special-use or reserved name that cannot be used with email.
#
# `EmailStr` de Pydantic delega en `email-validator`, que rechaza por diseño
# los nombres de uso especial: `.test`, `.example`, `.invalid` y `.localhost`.
# Se usa `.gt`, un TLD real. El correo no se envía a ninguna parte —el registro
# solo lo almacena— así que un dominio real que no existe es más seguro que uno
# reservado que la librería conoce.
#
# Conviene señalarlo porque el canary abortó por esto, y el veredicto fue
# «versión candidata defectuosa» cuando el defecto estaba en la prueba. Es el
# modo de fallo más caro de una puerta de calidad: un falso positivo enseña a
# la gente a promover a mano.
SUFIJO="$(printf '%s' "${HOSTNAME:-local}" | tail -c 12)-$(date +%s)"
CORREO="canary-${SUFIJO}@sa-p8.gt"
CLAVE="CanarioSeguro123"

limpiar() { rm -f "$GALLETAS" "$CUERPO"; }
trap limpiar EXIT

echo "── Prueba de integración contra ${BASE}"
echo "   usuario de la prueba: ${CORREO}"
echo

# ---------------------------------------------------------------------------
# paso <descripción> <método> <ruta> <código esperado> [cuerpo JSON] [fragmento]
# ---------------------------------------------------------------------------
paso() {
  descripcion="$1"; metodo="$2"; ruta="$3"; esperado="$4"
  json="${5:-}"; fragmento="${6:-}"

  if [ -n "$json" ]; then
    codigo=$(curl -s -o "$CUERPO" -w '%{http_code}' --max-time 15 \
      -X "$metodo" "${BASE}${ruta}" \
      -H 'Content-Type: application/json' \
      -c "$GALLETAS" -b "$GALLETAS" \
      -d "$json" || echo "000")
  else
    codigo=$(curl -s -o "$CUERPO" -w '%{http_code}' --max-time 15 \
      -X "$metodo" "${BASE}${ruta}" \
      -c "$GALLETAS" -b "$GALLETAS" || echo "000")
  fi

  if [ "$codigo" != "$esperado" ]; then
    printf '  ✗ %-44s HTTP %s (esperado %s)\n' "$descripcion" "$codigo" "$esperado"
    echo "      cuerpo: $(head -c 300 "$CUERPO")"
    FALLOS=$((FALLOS + 1))
    return 1
  fi

  if [ -n "$fragmento" ] && ! grep -q "$fragmento" "$CUERPO"; then
    printf '  ✗ %-44s HTTP %s pero falta «%s»\n' "$descripcion" "$codigo" "$fragmento"
    echo "      cuerpo: $(head -c 300 "$CUERPO")"
    FALLOS=$((FALLOS + 1))
    return 1
  fi

  printf '  ✓ %-44s HTTP %s\n' "$descripcion" "$codigo"
  return 0
}

# ---------------------------------------------------------------------------
# 1 · Registro — atraviesa gateway → auth-service → PostgreSQL
#
# 201 y no 200: el endpoint devuelve `HTTP_201_CREATED`. Aceptar «2xx» aquí
# dejaría pasar un cambio que convirtiera la creación en una actualización
# silenciosa.
# ---------------------------------------------------------------------------
paso "registro de usuario" POST "/api/auth/register" 201 \
  "{\"full_name\":\"Canario de la P8\",\"email\":\"${CORREO}\",\"password\":\"${CLAVE}\",\"role\":\"Cliente\"}" \
  '"email"' || true

# ---------------------------------------------------------------------------
# 2 · Sesión — comprueba el hash de bcrypt y la emisión del JWT
# ---------------------------------------------------------------------------
paso "inicio de sesión" POST "/api/auth/login" 200 \
  "{\"email\":\"${CORREO}\",\"password\":\"${CLAVE}\"}" \
  '"user"' || true

# ---------------------------------------------------------------------------
# 3 · Identidad — la prueba de que la cookie viaja y el gateway la reenvía
#
# Es el paso que valida la pieza más frágil del sistema: el gateway tiene que
# reenviar la cookie a auth-service Y auth-service tiene que verificar la firma
# con la MISMA clave que usó para emitirla. Un `jwtSecretKey` distinto entre
# los dos —o un Secret mal sellado— se manifiesta exactamente aquí.
# ---------------------------------------------------------------------------
paso "identidad de la sesión" GET "/api/auth/me" 200 "" "${CORREO}" || true

# ---------------------------------------------------------------------------
# 4 · Catálogo — GraphQL, otro lenguaje y otro estilo de API
#
# La ruta lleva `/graphql` al final y no es un detalle cosmético: el gateway
# proxea `/api/catalog` con `upstreamPrefix: ''`, así que reenvía la subruta
# tal cual. Apollo sirve en `/graphql` dentro de catalog-service, de modo que
# `POST /api/catalog` a secas llega como `POST /` y devuelve
# «Cannot POST /» con un 404 de Express —no un error de GraphQL—.
#
# catalog-service es Node.js con Apollo, mientras que auth y order son Python
# con FastAPI. Incluirlo prueba que el gateway proxea correctamente un POST con
# cuerpo GraphQL, que es un camino distinto del de un GET REST.
#
# Se comprueba `"products"` en la respuesta y no solo el 200: GraphQL devuelve
# 200 incluso cuando la consulta falla, con los errores dentro del cuerpo. Una
# prueba que solo mirara el código de estado aprobaría un catálogo roto.
# ---------------------------------------------------------------------------
paso "consulta GraphQL del catálogo" POST "/api/catalog/graphql" 200 \
  '{"query":"{ products(limit: 5) { items { id sku name price } total } }"}' \
  '"products"' || true

# ---------------------------------------------------------------------------
# 5 · Pedidos — ruta autenticada hacia el tercer servicio
# ---------------------------------------------------------------------------
paso "listado de pedidos del usuario" GET "/api/orders" 200 "" '' || true

# ---------------------------------------------------------------------------
# 6 · Notificaciones — el cuarto servicio, y el extremo de la cadena asíncrona
# ---------------------------------------------------------------------------
paso "bandeja de notificaciones" GET "/api/notifications" 200 "" '' || true

# ---------------------------------------------------------------------------
# 7 · Cierre de sesión — y comprobar que la sesión QUEDÓ cerrada
#
# Sin el segundo paso, esta comprobación no valdría nada: un `logout` que
# responde 200 y no invalida el token es indistinguible de uno que funciona.
# ---------------------------------------------------------------------------
paso "cierre de sesión" POST "/api/auth/logout" 200 "" '' || true
paso "la sesión quedó cerrada" GET "/api/orders" 401 "" '' || true

echo
if [ "$FALLOS" -gt 0 ]; then
  echo "── INTEGRACIÓN: ${FALLOS} paso(s) fallido(s) — se aborta el rollout"
  exit 1
fi
echo "── INTEGRACIÓN: los 8 pasos del flujo completo pasaron"
