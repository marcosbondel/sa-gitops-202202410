"""
main.py — Punto de entrada de order-service.

Responsabilidad: configurar la app, registrar los routers, preparar el esquema
al arrancar y soltar los recursos al apagar.

## Las tres sondas de Kubernetes

Este servicio expone tres endpoints de salud porque Kubernetes hace tres
preguntas distintas, y responder lo mismo a las tres provoca fallas que cuesta
diagnosticar:

  · `GET /health`         → **liveness**. "¿Sigue vivo el proceso?" No toca la
    base de datos a propósito. Si consultara PostgreSQL, una caída de la base
    reiniciaría todos los pods de todos los servicios en bucle —el clásico
    CrashLoopBackOff en cascada—, y reiniciar un proceso sano nunca ha
    arreglado una base caída.

  · `GET /health/ready`   → **readiness**. "¿Le mando tráfico?" Aquí sí se
    consulta la base, porque sin ella este servicio no puede atender nada útil.
    Fallar la readiness saca al pod del Service sin matarlo: deja de recibir
    peticiones y vuelve solo en cuanto la base responde.

  · `GET /health/startup` → **startup**. "¿Ya terminó de arrancar?" Cubre el
    arranque, que es lento porque incluye `create_all`. Mientras la startup no
    pase, Kubernetes no ejecuta liveness ni readiness. Sin ella habría que
    aflojar la liveness con un `initialDelaySeconds` grande, y esa holgura se
    pagaría para siempre: un pod colgado tardaría ese mismo tiempo en ser
    detectado durante toda la vida del despliegue.

El broker **no** se consulta en ninguna de las tres. Es deliberado: el servicio
degrada bien sin él —el pedido se guarda y solo se pierde el aviso—, así que un
broker caído no debe sacar de servicio al checkout completo.
"""

import logging
from collections.abc import AsyncGenerator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request, Response, status
from fastapi.responses import JSONResponse
from opentelemetry import trace
from opentelemetry.trace import Status, StatusCode
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import text

from app.config import settings
from app.telemetria import configurar_registro, instrumentar
from app.database import create_tables, engine
from app.dependencies.services import notification_gateway
from app.routers.order_router import router as order_router

# Práctica 10: registros en JSON con el `trace_id` del span activo, también
# los de uvicorn. Ver `app/telemetria.py`.
configurar_registro(settings.log_level)
logger = logging.getLogger(__name__)


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncGenerator[None, None]:
    await create_tables()
    yield
    # Al recibir SIGTERM, Kubernetes da un plazo de gracia antes de matar el
    # contenedor. Cerrar aquí la conexión con el broker evita dejar canales
    # colgados en RabbitMQ cada vez que el HPA reduce réplicas o el
    # RollingUpdate reemplaza un pod.
    close = getattr(notification_gateway, "close", None)
    if close is not None:
        await close()


app = FastAPI(
    title=settings.app_title,
    version=settings.app_version,
    description=settings.app_description,
    lifespan=lifespan,
    docs_url="/docs",
    redoc_url="/redoc",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=settings.cors_origins_list,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(order_router)

# Práctica 10: trazas de FastAPI, httpx, asyncpg y aio-pika, el histograma de
# cada petición y el servidor de métricas en :9464.
instrumentar(app)


@app.exception_handler(Exception)
async def error_no_controlado(_request: Request, error: Exception) -> JSONResponse:
    """
    Lo que ningún `except` previó. El error queda en el span —Tempo lo marca en
    rojo— y en el registro con su pila y el mismo `trace_id`.
    """
    span = trace.get_current_span()
    span.record_exception(error)
    span.set_status(Status(StatusCode.ERROR, "error no controlado en order-service"))
    logger.error("error no controlado", exc_info=error)
    return JSONResponse(status_code=500, content={"error": "INTERNAL_ERROR"})


@app.get("/health", tags=["Health Check"])
async def health_check() -> dict:
    """Liveness: el proceso responde. No consulta a nadie."""
    return {
        "status": "ok",
        "service": "order-service",
        "language": "Python 3.12 / FastAPI",
        "api": "REST",
        "version": settings.app_version,
        "environment": settings.app_env,
    }


@app.get("/health/startup", tags=["Health Check"])
async def startup_check() -> dict:
    """Startup: el arranque terminó y la app ya atiende."""
    return {"status": "ok", "service": "order-service"}


@app.get("/health/ready", tags=["Health Check"])
async def readiness_check(response: Response) -> dict:
    """
    Readiness: el servicio puede atender tráfico útil.

    El `SELECT 1` es la comprobación más barata que realmente prueba algo:
    obtiene una conexión del pool y va y vuelve del servidor. Comprobar solo
    que el pool existe no distinguiría una base caída de una sana.
    """
    try:
        async with engine.connect() as connection:
            await connection.execute(text("SELECT 1"))
    except Exception as error:  # noqa: BLE001 — cualquier fallo significa "no listo"
        logger.warning("Readiness en fallo: la base de datos no responde: %s", error)
        response.status_code = status.HTTP_503_SERVICE_UNAVAILABLE
        return {"status": "not-ready", "service": "order-service", "dependency": "postgresql"}

    return {"status": "ready", "service": "order-service"}


@app.get("/", tags=["Health Check"])
async def root() -> dict:
    """Información básica del servicio y de sus dependencias."""
    return {
        "service": "order-service",
        "role": "Orquestador de la saga de compra",
        "docs": "/docs",
        "depends_on": {
            "catalog-service": f"{settings.catalog_service_url}/graphql",
            "postgresql": f"{settings.postgres_host}:{settings.postgres_port}/{settings.postgres_db}",
            "rabbitmq": f"{settings.rabbitmq_host}:{settings.rabbitmq_port} → {settings.rabbitmq_exchange}",
        },
        "async_flow": "order.created / order.paid / order.cancelled → exchange sa.events",
    }
