# ---------------------------------------------------------------------------
# order-service — Python 3.12 / FastAPI · imagen multi-stage
#
# ## Qué cambió respecto de la Práctica 4 y por qué
#
# La imagen de la Práctica 4 era de una sola etapa sobre `python:3.12-slim`:
# instalaba las dependencias y copiaba el código sobre la misma capa. Funcionaba,
# pero enviaba a producción cosas que producción no necesita —pip, setuptools,
# los metadatos de instalación y la caché de compilación— y arrastraba la
# superficie de una Debian completa.
#
# Aquí hay dos etapas y dos decisiones distintas:
#
#   builder → instala las dependencias en un **entorno virtual aislado**
#             (/opt/venv). Es la etapa que puede ensuciarse: si mañana alguna
#             dependencia necesitara gcc, se agrega aquí y no sale de aquí.
#
#   runtime → parte de una imagen limpia y copia **solo el entorno virtual y el
#             código**. Nunca ejecuta pip, así que la imagen final no lleva ni
#             el gestor de paquetes ni un índice de red configurado.
#
# ## Por qué alpine y no slim
#
# `python:3.12-alpine` pesa poco más de un tercio que `python:3.12-slim`. El
# riesgo clásico de alpine con Python es que usa musl en lugar de glibc y las
# ruedas precompiladas (`manylinux`) no sirven, obligando a compilar en cada
# build. Se comprobó que no es el caso aquí: asyncpg, cryptography, bcrypt,
# aio-pika y uvloop publican ruedas `musllinux`, así que la instalación es una
# descarga y no una compilación.
#
# ## Por qué el usuario no root se crea aquí además de en el chart
#
# El chart declara `runAsNonRoot: true` y `runAsUser`, y eso es lo que de
# verdad manda en el clúster. Pero una imagen que solo funciona si alguien
# recuerda configurar el securityContext es una imagen insegura por defecto: si
# se ejecuta con `docker run`, o en un clúster con otra política, correría como
# root. La defensa se pone en los dos lados.
#
# ## Compatibilidad con readOnlyRootFilesystem
#
# El chart monta el contenedor con el sistema de archivos raíz de solo lectura.
# Por eso aquí no se escribe nada en tiempo de ejecución: `PYTHONDONTWRITEBYTECODE`
# evita los .pyc y el único directorio escribible es /tmp, que el chart monta
# como `emptyDir`.
# ---------------------------------------------------------------------------

# --------------------------- Etapa 1 · dependencias ------------------------
FROM python:3.12-alpine AS builder

# Un entorno virtual y no `--user`: copiar un directorio completo a la etapa
# siguiente es una sola instrucción y no depende de dónde deje pip los archivos.
ENV VIRTUAL_ENV=/opt/venv
RUN python -m venv $VIRTUAL_ENV
ENV PATH="$VIRTUAL_ENV/bin:$PATH"

WORKDIR /app

# El manifiesto primero: si no cambian las dependencias, Docker reutiliza la
# capa del `pip install` aunque haya cambiado todo el código.
COPY requirements.txt .
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir -r requirements.txt

# --------------------------- Etapa 2 · ejecución ---------------------------
FROM python:3.12-alpine AS runtime

ENV VIRTUAL_ENV=/opt/venv \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PYTHONPATH=/app

# Usuario sin privilegios con UID fijo. El UID importa: el chart declara el
# mismo número en `runAsUser`, y si no coincidieran, los archivos copiados
# pertenecerían a un usuario que dentro del pod no existe.
RUN addgroup -g 10001 -S appuser && \
    adduser -u 10001 -S appuser -G appuser

WORKDIR /app

COPY --from=builder --chown=appuser:appuser /opt/venv /opt/venv
COPY --chown=appuser:appuser ./app ./app

USER 10001

# 9464: métricas de OpenTelemetry para Prometheus (Práctica 10).
EXPOSE 8000 9464

# Sonda para `docker run`. En el clúster manda el chart, que define liveness,
# readiness y startup por separado; esta cubre el caso de ejecutar la imagen
# fuera de Kubernetes.
HEALTHCHECK --interval=15s --timeout=5s --start-period=20s --retries=5 \
    CMD python -c "import urllib.request; urllib.request.urlopen('http://localhost:8000/health')"

# `--no-access-log`: el registro de acceso lo escribe la aplicación, en JSON y
# con el `trace_id` (Práctica 10, `app/telemetria.py`).
CMD ["uvicorn", "app.main:app", "--host", "0.0.0.0", "--port", "8000", "--no-access-log"]
