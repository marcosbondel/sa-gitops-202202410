"""
telemetria.py — OpenTelemetry en order-service (Práctica 10)

Las tres señales, cada una por su camino:

  trazas    → OTLP/HTTP al Collector (`OTEL_EXPORTER_OTLP_ENDPOINT`) → Tempo.
  métricas  → expuestas en :9464/metrics y raspadas por Prometheus.
  registros → JSON por la salida estándar; el Collector los lee del nodo → Loki.

Es el equivalente en Python de `api-gateway/src/telemetria/` (Node). Lo que
tiene que ser idéntico entre los dos lenguajes lo es a propósito:

  · el propagador (W3C Trace Context): es el contrato que convierte la llamada
    gateway → order-service → catalog-service en UNA traza;
  · el histograma `http.server.request.duration`, con los mismos atributos y
    los mismos cortes, para que una sola consulta de PromQL sirva para los tres
    servicios;
  · la forma de la línea de registro: `timestamp`, `level`, `service`,
    `message`, `trace_id`, `span_id`.

Las razones de cada decisión (métricas raspadas y no empujadas, proveedor de
métricas no global, cortes alineados a los SLO) están en el encabezado de
`api-gateway/src/telemetria/iniciar.ts` y no se repiten aquí.

order-service es además el dueño de las **métricas de negocio**: es el único
servicio que sabe que una compra ocurrió, cuánto valía o por qué no se pudo
hacer. Están al final de este archivo.
"""

import json
import logging
import os
import sys
import time
from datetime import UTC, datetime
from typing import Any

from opentelemetry import propagate, trace
from opentelemetry.baggage.propagation import W3CBaggagePropagator
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.exporter.prometheus import PrometheusMetricReader
from opentelemetry.instrumentation.aio_pika import AioPikaInstrumentor
from opentelemetry.instrumentation.asyncpg import AsyncPGInstrumentor
from opentelemetry.instrumentation.fastapi import FastAPIInstrumentor
from opentelemetry.instrumentation.httpx import HTTPXClientInstrumentor
from opentelemetry.propagators.composite import CompositePropagator
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from prometheus_client import start_http_server
from starlette.requests import Request
from starlette.routing import Match

NOMBRE_SERVICIO = os.getenv("OTEL_SERVICE_NAME", "order-service")
VERSION = os.getenv("APP_VERSION", "desconocida")
PUERTO_METRICAS = int(os.getenv("METRICS_PORT", "9464"))
DESACTIVADO = os.getenv("OTEL_SDK_DISABLED", "false").lower() == "true"

CORTES_SEGUNDOS = [0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2.5, 5, 10]

# `Resource.create` lee también OTEL_RESOURCE_ATTRIBUTES; el chart no la usa,
# pero un tercero podría añadir atributos sin tocar el código.
_recurso = Resource.create(
    {
        "service.name": NOMBRE_SERVICIO,
        "service.version": VERSION,
        "deployment.environment.name": os.getenv("APP_ENV", "development"),
        "k8s.pod.name": os.getenv("POD_NAME", ""),
    }
)

# ---------------------------------------------------------------------------
# Trazas y propagación
# ---------------------------------------------------------------------------
_proveedor_trazas = TracerProvider(resource=_recurso)
if not DESACTIVADO:
    _proveedor_trazas.add_span_processor(BatchSpanProcessor(OTLPSpanExporter()))
trace.set_tracer_provider(_proveedor_trazas)

# El mismo par de propagadores que el gateway: extraer `traceparent` de la
# petición que llega e inyectarlo en la llamada a catalog-service (httpx) y en
# las cabeceras del mensaje que se publica en RabbitMQ (aio-pika).
propagate.set_global_textmap(
    CompositePropagator([TraceContextTextMapPropagator(), W3CBaggagePropagator()])
)

# ---------------------------------------------------------------------------
# Métricas
# ---------------------------------------------------------------------------
_lector_prometheus = PrometheusMetricReader()
_proveedor_metricas = MeterProvider(resource=_recurso, metric_readers=[_lector_prometheus])
medidor = _proveedor_metricas.get_meter(NOMBRE_SERVICIO, VERSION)

_duracion = medidor.create_histogram(
    "http.server.request.duration",
    unit="s",
    description="Duración de las peticiones HTTP atendidas, desde que llegan hasta que se responden.",
    explicit_bucket_boundaries_advisory=CORTES_SEGUNDOS,
)


# ---------------------------------------------------------------------------
# Registro estructurado
# ---------------------------------------------------------------------------
# `color_message` lo añade uvicorn: el mismo mensaje con códigos de color ANSI.
_ATRIBUTOS_DE_LOGRECORD = set(vars(logging.makeLogRecord({}))) | {"message", "asctime", "taskName", "color_message"}


class FormatoJSON(logging.Formatter):
    """
    Una línea de JSON por registro, con el `trace_id` del span activo.

    Los campos estructurados se pasan con `extra={...}`: todo lo que no sea un
    atributo estándar de `LogRecord` se copia tal cual a la línea. Así un
    registro de error lleva el servicio de abajo, la URL y el tipo de error
    como campos consultables en Loki, y no enterrados dentro de un mensaje.
    """

    def format(self, record: logging.LogRecord) -> str:
        contexto = trace.get_current_span().get_span_context()
        linea: dict[str, Any] = {
            "timestamp": datetime.fromtimestamp(record.created, UTC).isoformat(timespec="milliseconds").replace("+00:00", "Z"),
            "level": record.levelname.lower(),
            "service": NOMBRE_SERVICIO,
            "logger": record.name,
            "message": record.getMessage(),
            "trace_id": format(contexto.trace_id, "032x") if contexto.is_valid else None,
            "span_id": format(contexto.span_id, "016x") if contexto.is_valid else None,
        }
        for clave, valor in vars(record).items():
            if clave not in _ATRIBUTOS_DE_LOGRECORD and not clave.startswith("_"):
                linea[clave] = valor
        if record.exc_info:
            tipo, error, _ = record.exc_info
            linea["error.type"] = tipo.__name__ if tipo else None
            linea["error.message"] = str(error)
            linea["error.stack"] = self.formatException(record.exc_info)
        return json.dumps(linea, ensure_ascii=False, default=str)


def configurar_registro(nivel: str) -> None:
    """
    Todo a JSON: la aplicación y también uvicorn.

    uvicorn configura sus propios manejadores ANTES de importar la aplicación,
    con formato de texto. Si no se reemplazan aquí, los mensajes de arranque y
    de error del servidor saldrían en texto plano, mezclados con el JSON, y el
    Collector tendría que adivinar qué línea es cuál. El registro de acceso de
    uvicorn se apaga en el Dockerfile (`--no-access-log`): lo reemplaza
    `medir_peticiones`, que además sabe la ruta, la duración y el `trace_id`.
    """
    manejador = logging.StreamHandler(sys.stdout)
    manejador.setFormatter(FormatoJSON())
    raiz = logging.getLogger()
    raiz.handlers = [manejador]
    raiz.setLevel(getattr(logging, nivel.upper(), logging.INFO))
    for nombre in ("uvicorn", "uvicorn.error"):
        registro_uvicorn = logging.getLogger(nombre)
        registro_uvicorn.handlers = [manejador]
        registro_uvicorn.propagate = False
    # Sin manejador: uvicorn decide si escribe el acceso según
    # `hasHandlers()`, y darle uno aquí lo volvería a encender.
    acceso = logging.getLogger("uvicorn.access")
    acceso.handlers = []
    acceso.propagate = False


log = logging.getLogger("order-service")


# ---------------------------------------------------------------------------
# Instrumentación de la aplicación
# ---------------------------------------------------------------------------
def _ruta_de(request: Request) -> str:
    """
    La plantilla de la ruta (`/api/orders/{order_id}/pay`), no el camino real.

    Mismo motivo que en el gateway: con el identificador del pedido dentro de
    la etiqueta, cada compra crearía series nuevas en Prometheus.
    """
    for ruta in request.app.router.routes:
        coincide, _ = ruta.matches(request.scope)
        if coincide == Match.FULL:
            return getattr(ruta, "path", "otra")
    return "otra"


def instrumentar(app: Any) -> None:
    """Spans de FastAPI, httpx, asyncpg y aio-pika; servidor de métricas."""
    # Las sondas de Kubernetes no se trazan: no son usuarios.
    FastAPIInstrumentor.instrument_app(app, excluded_urls="health", tracer_provider=_proveedor_trazas)
    HTTPXClientInstrumentor().instrument(tracer_provider=_proveedor_trazas)
    AsyncPGInstrumentor().instrument(tracer_provider=_proveedor_trazas)
    AioPikaInstrumentor().instrument(tracer_provider=_proveedor_trazas)

    @app.middleware("http")
    async def medir_peticiones(request: Request, call_next):  # type: ignore[no-untyped-def]
        if request.url.path.startswith("/health"):
            return await call_next(request)
        inicio = time.perf_counter()
        estado = 500
        try:
            respuesta = await call_next(request)
            estado = respuesta.status_code
            return respuesta
        finally:
            segundos = time.perf_counter() - inicio
            ruta = _ruta_de(request)
            _duracion.record(
                segundos,
                {
                    "http.request.method": request.method,
                    "http.route": ruta,
                    "http.response.status_code": estado,
                },
            )
            campos = {
                "http.request.method": request.method,
                "http.route": ruta,
                "url.path": request.url.path,
                "http.response.status_code": estado,
                "duration_ms": round(segundos * 1000, 1),
                "correlation_id": request.headers.get("x-correlation-id"),
            }
            if estado >= 500:
                log.error("petición fallida", extra=campos)
            else:
                log.info("petición atendida", extra=campos)

    if not DESACTIVADO:
        start_http_server(PUERTO_METRICAS, addr="0.0.0.0")


# ---------------------------------------------------------------------------
# Métricas de negocio
#
# Lo que le importa a quien vende, no a quien opera los pods: cuántos pedidos
# entran, cuántos se pagan, cuánto dinero representan y —sobre todo— cuántos
# se pierden y por qué. Un `pedidos_rechazados_total{motivo="catalogo_no_disponible"}`
# que sube es una frase que entiende cualquier gerente: «estamos perdiendo
# ventas porque el catálogo no contesta».
#
# En Prometheus: `pedidos_creados_total`, `pedidos_rechazados_total`,
# `pagos_confirmados_total`, `pedidos_cancelados_total` y
# `ventas_monto_total`.
# ---------------------------------------------------------------------------
pedidos_creados = medidor.create_counter(
    "pedidos.creados", unit="{pedido}", description="Pedidos registrados con éxito (checkout completado)."
)
pedidos_rechazados = medidor.create_counter(
    "pedidos.rechazados",
    unit="{pedido}",
    description="Intentos de compra que no terminaron en pedido, por motivo.",
)
pagos_confirmados = medidor.create_counter(
    "pagos.confirmados", unit="{pago}", description="Pedidos pagados."
)
pedidos_cancelados = medidor.create_counter(
    "pedidos.cancelados", unit="{pedido}", description="Pedidos cancelados por el cliente."
)
ventas_monto = medidor.create_counter(
    "ventas.monto",
    unit="{moneda}",
    description="Monto cobrado en pedidos pagados, en la moneda del pedido.",
)
