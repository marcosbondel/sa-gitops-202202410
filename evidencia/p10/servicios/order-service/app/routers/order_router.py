"""
order_router.py — Principio SRP

Única responsabilidad: exponer los endpoints HTTP de pedidos y traducir entre
el mundo HTTP y la capa de servicio.

Aquí no hay lógica de negocio: no se decide qué transiciones son válidas ni
quién puede ver qué. Lo único que se hace es convertir errores de dominio en
códigos de estado, y hay una correspondencia deliberada entre ambos:

    EmptyCart / DuplicateItem / ProductNotAvailable → 400  pedido mal formado
    OrderNotFound                                   → 404  no existe
    OrderAccessDenied                               → 403  existe, no es tuyo
    InvalidOrderState                               → 409  choca con el estado
    UpstreamError                                   → 503  no fue culpa tuya
"""

import logging
import uuid

from fastapi import APIRouter, HTTPException, Query, status

from app.clients.graphql_client import UpstreamError
from app.dependencies.auth import CurrentRequester
from app.dependencies.services import OrderServiceDep
from app.models.order import OrderStatus
from app.schemas.order import (
    CreateOrderRequest,
    OrderPageResponse,
    OrderResponse,
)
from app.telemetria import pedidos_rechazados
from app.services.exceptions import (
    DuplicateItemError,
    EmptyCartError,
    InvalidOrderStateError,
    OrderAccessDeniedError,
    OrderNotFoundError,
    ProductNotAvailableError,
)

router = APIRouter(prefix="/api/orders", tags=["Pedidos"])
log = logging.getLogger(__name__)

# Práctica 10: el motivo de cada compra que no se concretó, en el vocabulario
# del negocio. Es la etiqueta de `pedidos_rechazados_total`.
_MOTIVO_RECHAZO = {
    EmptyCartError: "carrito_vacio",
    DuplicateItemError: "producto_repetido",
    ProductNotAvailableError: "producto_no_disponible",
}


def _upstream_unavailable(error: UpstreamError) -> HTTPException:
    """
    503 cuando un servicio del que dependemos no responde.

    Se nombra el servicio afectado en la respuesta: quien opera el sistema
    necesita saber cuál de los servicios se cayó, y esa información no
    compromete nada que un atacante no pueda deducir del mapa público de rutas.
    """
    return HTTPException(
        status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
        detail=(
            f"El servicio {error.service} no está disponible en este momento "
            f"({error.detail}). El pedido no se procesó; intente de nuevo."
        ),
    )


@router.post(
    "",
    response_model=OrderResponse,
    status_code=status.HTTP_201_CREATED,
    summary="Crear un pedido (checkout)",
)
async def create_order(
    payload: CreateOrderRequest,
    requester: CurrentRequester,
    order_service: OrderServiceDep,
) -> OrderResponse:
    """
    Ejecuta la saga de compra: consulta precios al catálogo, crea el pedido y
    publica el evento `order.created` en el broker.

    El pedido nace en `PENDING_PAYMENT`. La respuesta **no** garantiza que la
    notificación al cliente ya exista: el consumidor la procesa después, de
    forma independiente. Consultar `/api/notifications` inmediatamente después
    de este endpoint puede devolver una lista vacía sin que nada esté mal; ese
    es el precio de la consistencia eventual, y decirlo aquí evita que se
    interprete como un defecto.
    """
    try:
        order = await order_service.create_order(payload, requester)
    except (EmptyCartError, DuplicateItemError, ProductNotAvailableError) as error:
        pedidos_rechazados.add(1, {"motivo": _MOTIVO_RECHAZO[type(error)]})
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(error)) from error
    except UpstreamError as error:
        # El cliente quería comprar y el sistema no lo dejó: es la venta
        # perdida que más importa, porque no fue culpa de nadie del lado del
        # cliente.
        pedidos_rechazados.add(1, {"motivo": f"{error.service.removesuffix('-service')}_no_disponible"})
        log.error(
            "compra rechazada: un servicio del que depende el checkout no respondió",
            extra={"upstream.service": error.service, "error.message": error.detail},
        )
        raise _upstream_unavailable(error) from error

    return OrderResponse.model_validate(order)


@router.get(
    "",
    response_model=OrderPageResponse,
    summary="Historial de pedidos",
)
async def list_orders(
    requester: CurrentRequester,
    order_service: OrderServiceDep,
    status_filter: OrderStatus | None = Query(
        default=None, alias="status", description="Filtra por estado del pedido"
    ),
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
) -> OrderPageResponse:
    """
    Devuelve los pedidos del usuario autenticado.

    Un Admin recibe los de todos los usuarios; un Cliente, solo los suyos. La
    decisión la toma la capa de servicio, no este endpoint.
    """
    orders, total = await order_service.list_orders(requester, status_filter, limit, offset)

    return OrderPageResponse(
        items=[OrderResponse.model_validate(order) for order in orders],
        total=total,
        limit=limit,
        offset=offset,
    )


@router.get(
    "/{order_id}",
    response_model=OrderResponse,
    summary="Detalle de un pedido",
)
async def get_order(
    order_id: uuid.UUID,
    requester: CurrentRequester,
    order_service: OrderServiceDep,
) -> OrderResponse:
    """Detalle de un pedido propio (o de cualquiera, si el rol es Admin)."""
    try:
        order = await order_service.get_order(order_id, requester)
    except OrderNotFoundError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except OrderAccessDeniedError as error:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error

    return OrderResponse.model_validate(order)


@router.post(
    "/{order_id}/pay",
    response_model=OrderResponse,
    summary="Pagar un pedido",
)
async def pay_order(
    order_id: uuid.UUID,
    requester: CurrentRequester,
    order_service: OrderServiceDep,
) -> OrderResponse:
    """
    Confirma el pago: la reserva pasa a firme y la mercadería sale de bodega.

    En un sistema real aquí entraría la pasarela de pagos. Se omite a
    propósito: cobrar de verdad es un microservicio más con su propio ciclo de
    vida, y simularlo con un `if` dentro de este endpoint daría una idea
    equivocada de dónde debería vivir.
    """
    try:
        order = await order_service.pay_order(order_id, requester)
    except OrderNotFoundError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except OrderAccessDeniedError as error:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except InvalidOrderStateError as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    except UpstreamError as error:
        raise _upstream_unavailable(error) from error

    return OrderResponse.model_validate(order)


@router.post(
    "/{order_id}/cancel",
    response_model=OrderResponse,
    summary="Cancelar un pedido",
)
async def cancel_order(
    order_id: uuid.UUID,
    requester: CurrentRequester,
    order_service: OrderServiceDep,
    reason: str | None = Query(default=None, max_length=500, description="Motivo de la cancelación"),
) -> OrderResponse:
    """
    Cancela un pedido pendiente y publica el evento `order.cancelled`.

    Es la compensación explícita de la saga de compra.
    """
    try:
        order = await order_service.cancel_order(order_id, reason, requester)
    except OrderNotFoundError as error:
        raise HTTPException(status_code=status.HTTP_404_NOT_FOUND, detail=str(error)) from error
    except OrderAccessDeniedError as error:
        raise HTTPException(status_code=status.HTTP_403_FORBIDDEN, detail=str(error)) from error
    except InvalidOrderStateError as error:
        raise HTTPException(status_code=status.HTTP_409_CONFLICT, detail=str(error)) from error
    except UpstreamError as error:
        raise _upstream_unavailable(error) from error

    return OrderResponse.model_validate(order)
