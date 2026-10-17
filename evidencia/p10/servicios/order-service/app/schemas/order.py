"""
schemas/order.py — Principios SRP e ISP

Única responsabilidad: definir y validar los contratos HTTP de order-service.

ISP en la práctica: hay un schema para lo que entra y otro para lo que sale, en
lugar de un modelo único que sirva para las dos cosas. La ventaja no es
estética: `OrderResponse` sencillamente **no tiene** un campo donde pudiera
colarse un dato interno, así que la fuga es imposible por construcción y no por
disciplina de quien escribe el endpoint.
"""

import uuid
from datetime import datetime
from decimal import Decimal

from pydantic import BaseModel, ConfigDict, Field

from app.models.order import OrderStatus

# Tope por renglón. Un carrito con 10 000 unidades de un artículo es casi
# siempre un error de captura o una prueba de carga, no una venta.
MAX_QUANTITY_PER_LINE = 100
MAX_LINES_PER_ORDER = 50


class OrderItemRequest(BaseModel):
    """Un renglón del carrito tal como lo manda el cliente."""

    product_id: uuid.UUID = Field(description="Identificador del producto en el catálogo")
    quantity: int = Field(
        gt=0,
        le=MAX_QUANTITY_PER_LINE,
        description=f"Unidades a comprar (1 a {MAX_QUANTITY_PER_LINE})",
    )


class CreateOrderRequest(BaseModel):
    """
    Cuerpo de POST /api/orders.

    El cliente manda qué y cuánto, nunca el precio: el precio lo resuelve
    order-service consultando al catálogo. Aceptarlo del cliente permitiría
    comprar una laptop por un quetzal cambiando un número en la petición.
    """

    items: list[OrderItemRequest] = Field(
        min_length=1,
        max_length=MAX_LINES_PER_ORDER,
        description="Renglones del carrito",
    )

    model_config = ConfigDict(
        json_schema_extra={
            "example": {
                "items": [
                    {"product_id": "11111111-1111-4111-8111-000000000004", "quantity": 2},
                    {"product_id": "11111111-1111-4111-8111-000000000005", "quantity": 1},
                ]
            }
        }
    )


class OrderItemResponse(BaseModel):
    """Renglón del pedido, con la fotografía del producto al momento de comprar."""

    product_id: uuid.UUID
    sku: str
    product_name: str
    unit_price: Decimal
    quantity: int
    line_total: Decimal

    model_config = ConfigDict(from_attributes=True)


class OrderResponse(BaseModel):
    """Representación pública de un pedido."""

    id: uuid.UUID
    user_id: str
    status: OrderStatus
    currency: str
    subtotal: Decimal
    total: Decimal
    status_reason: str | None = None
    items: list[OrderItemResponse]
    created_at: datetime
    updated_at: datetime

    model_config = ConfigDict(from_attributes=True)


class OrderPageResponse(BaseModel):
    """Página de pedidos, con el total para poder pintar el paginador."""

    items: list[OrderResponse]
    total: int
    limit: int
    offset: int



class MessageResponse(BaseModel):
    """Respuesta simple con un mensaje."""

    message: str
