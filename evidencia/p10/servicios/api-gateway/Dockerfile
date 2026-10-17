# ---------------------------------------------------------------------------
# api-gateway — Node 20 / TypeScript · imagen multi-stage
#
# ## Qué cambió respecto de la Práctica 4
#
# Aquella imagen ya tenía dos etapas, pero desperdiciaba buena parte del
# beneficio y su etapa final seguía siendo `node:20-alpine` completa. Aquí hay
# tres cambios, y conviene separar cuál gana peso y cuál gana otra cosa:
#
#   1. **`npm ci` en vez de `npm install`** (reproducibilidad, no tamaño).
#      `ci` instala exactamente lo que dice package-lock.json y falla si el lock
#      no concuerda; `install` puede resolver una versión distinta a la
#      probada. Una imagen que se despliega debe ser reproducible byte a byte,
#      no "más o menos la misma".
#
#   2. **Se instala una sola vez y se poda** (tamaño y tiempo de build). La
#      Práctica 4 volvía a correr `npm install --omit=dev` en la etapa de
#      ejecución: descargaba todo por segunda vez, necesitaba red durante el
#      build de runtime y dejaba la caché de npm en la capa final. Aquí el
#      builder instala, compila y luego `npm prune --omit=dev`; la etapa final
#      solo copia directorios ya resueltos.
#
#   3. **La etapa final no es una imagen de Node** (tamaño). Es `alpine` con el
#      binario `node` copiado encima. Eso quita npm, npx, yarn, corepack y los
#      encabezados de compilación de módulos nativos: unos 21 MB menos y, sobre
#      todo, mucha menos superficie. Sin npm dentro del contenedor, quien logre
#      ejecución de código no puede instalar paquetes ni ejecutar scripts
#      arbitrarios de package.json; combinado con `readOnlyRootFilesystem`,
#      tampoco puede dejar nada escrito.
#
#      Borrar npm con un `rm` en la etapa final **no** habría servido para el
#      tamaño: las capas de Docker son aditivas y el contenido borrado sigue
#      ocupando espacio en la capa donde se agregó. Solo cambiando de imagen
#      base se recupera realmente.
#
#      Se instalan `libstdc++` y `libgcc` porque el binario de Node los enlaza
#      dinámicamente. Sin ellos la imagen construye y falla al arrancar, que es
#      la peor forma de fallar.
#
# ## Compatibilidad con readOnlyRootFilesystem
#
# El chart monta el sistema de archivos raíz de solo lectura. Node no escribe
# nada en ejecución y el único directorio escribible es /tmp, que el chart monta
# como `emptyDir`.
# ---------------------------------------------------------------------------

# --------------------------- Etapa 1 · compilación -------------------------
FROM node:20-alpine AS builder

WORKDIR /app

# Primero el manifiesto: si no cambian las dependencias, Docker reutiliza la
# capa del `npm ci` aunque haya cambiado todo el código.
COPY package*.json ./
RUN npm ci

COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# Se quitan las dependencias de desarrollo del árbol ya instalado. Es más
# rápido que reinstalar y garantiza que las que quedan son exactamente las
# mismas que se usaron para compilar.
RUN npm prune --omit=dev

# --------------------------- Etapa 2 · ejecución ---------------------------
FROM alpine:3.21 AS runtime

# Dependencias dinámicas del binario de Node. `--no-cache` evita dejar el
# índice de apk en la imagen.
RUN apk add --no-cache libstdc++ libgcc

# Solo el intérprete. Sin npm, sin npx, sin yarn, sin corepack.
COPY --from=builder /usr/local/bin/node /usr/local/bin/node

# Usuario sin privilegios con UID fijo. El número importa: el chart declara el
# mismo en `runAsUser`, y si no coincidieran, los archivos copiados
# pertenecerían a un usuario que dentro del pod no existe.
RUN addgroup -g 10001 -S appuser && \
    adduser -u 10001 -S appuser -G appuser

WORKDIR /app
ENV NODE_ENV=production

COPY --from=builder --chown=appuser:appuser /app/node_modules ./node_modules
COPY --from=builder --chown=appuser:appuser /app/dist ./dist
COPY --chown=appuser:appuser package.json ./

USER 10001

# 9464: métricas de OpenTelemetry para Prometheus (Práctica 10).
EXPOSE 8080 9464

# Sonda para `docker run`. En el clúster manda el chart, que define liveness,
# readiness y startup por separado; esta cubre el caso de ejecutar la imagen
# fuera de Kubernetes.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD wget --quiet --spider http://localhost:8080/health/self || exit 1

CMD ["node", "dist/index.js"]
