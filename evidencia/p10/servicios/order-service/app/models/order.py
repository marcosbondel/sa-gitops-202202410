"""
models/order.py — Principio SRP

Única responsabilidad: describir cómo se persisten los pedidos.

## Por qué el pedido copia el nombre y el precio del producto

`OrderItem` guarda `sku`, `product_name` y `unit_price` en lugar de limitarse a
apuntar al producto del catálogo. Es deliberado y es una consecuencia directa
de tener una base por servicio:

  1. **No puede haber clave foránea** hacia `catalog_db`: está en otro
     contenedor y otro motor. La integridad referencial entre servicios no
     existe, y pretender lo contrario es el error clásico al partir un
     monolito.
  2. **El precio de una compra es histórico.** Si mañana la laptop sube de
     Q12,999 a Q14,499, el pedido de ayer tiene que seguir diciendo Q12,999.
     Un pedido que consultara el precio actual reescribiría la contabilidad
     cada vez que alguien cambia una etiqueta.

Al momento de la compra, `order-service` le pide al catálogo los datos y toma
una fotografía. A esto se le llama *snapshot* del precio y es lo que hace que
el pedido siga siendo legible aunque el producto se dé de baja.
"""

import uuid
from datetime import UTC, datetime
from decimal import Decimal
from enum import Enum

from sqlalchemy import CheckConstraint, DateTime, ForeignKey, Integer, Numeric, String
from sqlalchemy import Enum as SAEnum
from sqlalchemy.dialects.postgresql import UUID
from sqlalchemy.orm import Mapped, mapped_column, relationship

from app.database import Base


class OrderStatus(str, Enum):
    """
    Estados posibles de un pedido.

    Las transiciones válidas son pocas y todas de ida:

        PENDING_PAYMENT ──pagar──▶ PAID
                        ──cancelar──▶ CANCELLED
                        ──sin existencias──▶ FAILED

    Un pedido pagado no vuelve atrás: revertir dinero es un reembolso, que es
    otra operación con su propio registro, no un cambio de estado.
    """

    PENDING_PAYMENT = "PENDING_PAYMENT"
    PAID = "PAID"
    CANCELLED = "CANCELLED"
    FAILED = "FAILED"


class Order(Base):
    """Pedido de un cliente."""

    __tablename__ = "orders"

    __table_args__ = (
        CheckConstraint("subtotal >= 0", name="ck_order_subtotal_positivo"),
        CheckConstraint("total >= 0", name="ck_order_total_positivo"),
    )

    id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True),
        primary_key=True,
        default=uuid.uuid4,
        comment="Identificador del pedido. Es también la clave de la reserva en inventario.",
    )

    # Identificador del usuario tal como lo resolvió auth-service. Se guarda
    # como texto y no como clave foránea porque los usuarios viven en auth_db,
    # que es una base distinta en otro contenedor.
    user_id: Mapped[str] = mapped_column(String(60), nullable=False, index=True)
    user_email: Mapped[str] = mapped_column(String(255), nullable=False)

    status: Mapped[OrderStatus] = mapped_column(
        SAEnum(
            OrderStatus,
            name="order_status",
            native_enum=False,
            length=20,
            values_callable=lambda enum_cls: [member.value for member in enum_cls],
        ),
        nullable=False,
        default=OrderStatus.PENDING_PAYMENT,
        index=True,
    )

    currency: Mapped[str] = mapped_column(String(3), nullable=False, default="GTQ")
    # Numeric y no Float: los flotantes binarios no representan exactamente
    # valores como 0.10, y en dinero ese error se acumula sumando líneas.
    subtotal: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False, default=Decimal("0"))
    total: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False, default=Decimal("0"))

    # Motivo del fallo o de la cancelación, para poder explicárselo al cliente.
    status_reason: Mapped[str | None] = mapped_column(String(500), nullable=True)

    created_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True), nullable=False, default=lambda: datetime.now(UTC)
    )
    updated_at: Mapped[datetime] = mapped_column(
        DateTime(timezone=True),
        nullable=False,
        default=lambda: datetime.now(UTC),
        onupdate=lambda: datetime.now(UTC),
    )

    items: Mapped[list["OrderItem"]] = relationship(
        back_populates="order",
        cascade="all, delete-orphan",
        # Los renglones se cargan siempre junto con el pedido: no existe un
        # caso de uso que quiera un pedido sin saber qué se compró, y con
        # carga perezosa cada consulta de listado dispararía una consulta extra
        # por pedido (el problema N+1).
        lazy="selectin",
    )

    def __repr__(self) -> str:
        return f"<Order id={self.id} status={self.status.value} total={self.total}>"


class OrderItem(Base):
    """Renglón de un pedido, con la fotografía del producto al momento de comprar."""

    __tablename__ = "order_items"

    __table_args__ = (
        CheckConstraint("quantity > 0", name="ck_item_cantidad_positiva"),
        CheckConstraint("unit_price >= 0", name="ck_item_precio_positivo"),
    )

    id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), primary_key=True, default=uuid.uuid4)

    order_id: Mapped[uuid.UUID] = mapped_column(
        UUID(as_uuid=True), ForeignKey("orders.id", ondelete="CASCADE"), nullable=False, index=True
    )

    # Id del producto en catalog_db. Sin clave foránea: otra base, otro servicio.
    product_id: Mapped[uuid.UUID] = mapped_column(UUID(as_uuid=True), nullable=False)

    sku: Mapped[str] = mapped_column(String(40), nullable=False)
    product_name: Mapped[str] = mapped_column(String(200), nullable=False)
    unit_price: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)
    quantity: Mapped[int] = mapped_column(Integer, nullable=False)
    line_total: Mapped[Decimal] = mapped_column(Numeric(12, 2), nullable=False)

    order: Mapped[Order] = relationship(back_populates="items")

    def __repr__(self) -> str:
        return f"<OrderItem sku={self.sku} x{self.quantity}>"
