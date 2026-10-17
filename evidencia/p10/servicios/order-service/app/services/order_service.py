"""
order_service.py — Principios SRP y DIP

Única responsabilidad: las reglas de negocio del pedido y la **orquestación de
la saga de compra**.

## Qué es aquí una saga y por qué hace falta

Comprar toca dos bases de datos lógicas que viven separadas: `order_db` (el
pedido) y `notification_db` (el aviso). Una transacción no puede abarcarlas:
`BEGIN` y `COMMIT` solo existen dentro de una misma base, y aunque en esta
práctica ambas viven en el mismo StatefulSet de PostgreSQL, cada servicio solo
tiene credenciales para la suya. El aislamiento es deliberado: si un día se
separan en dos motores, no cambia una línea de este archivo.

La alternativa es una **saga**: una secuencia de pasos locales, cada uno con
su propia transacción, más una acción compensatoria que deshace lo hecho
cuando un paso posterior falla.

    1. Consultar precios al catálogo        (sin efecto: nada que deshacer)
    2. Crear el pedido en PENDING_PAYMENT   (compensa: marcarlo FAILED)
    3. Publicar el evento en el broker      (sin compensación: ver abajo)

## Qué cambió respecto de la Práctica 4

El paso 3 era una llamada HTTP a notification-service y el checkout esperaba su
respuesta. Ahora es una publicación en RabbitMQ que retorna de inmediato.

El código de este archivo es idéntico —sigue llamando `self._notifications.
notify(...)`— porque lo que cambió fue la implementación detrás de la
abstracción, no la política. Lo que sí cambió es el **significado de que ese
paso tenga éxito**: antes, "notificado" quería decir que notification-service
ya lo había registrado; ahora quiere decir que el mensaje está en la cola y
alguien lo procesará. Es una promesa más débil y hay que decirlo en voz alta,
porque la API de consulta hereda esa debilidad: justo después del checkout, la
notificación puede todavía no existir.

Ese paso sigue sin compensación, por el mismo motivo de siempre: no se cancela
una compra porque un correo no salió. Las compensaciones se diseñan por
impacto de negocio, no por simetría técnica.

## Sobre el inventario

En la Práctica 4 la saga tenía un cuarto paso —reservar existencias en
inventory-service, con `release` como compensación— que era el ejemplo más
claro de compensación real. La Práctica 5 limita el alcance a cuatro
microservicios e inventory-service quedó fuera; el paso se eliminó en lugar de
dejarlo llamando a un servicio que no existe.

DIP: el constructor recibe el repositorio y los gateways como abstracciones.
Este archivo no importa httpx, ni aio_pika, ni SQLAlchemy, y se puede probar
inyectando dobles que no hablan con nadie.
"""

import logging
import uuid
from decimal import Decimal

from app.clients.audit_client import AuditPublisher
from app.clients.catalog_client import CatalogGateway
from app.clients.graphql_client import CallerContext
from app.clients.notification_client import NotificationGateway
from app.models.order import Order, OrderItem, OrderStatus
from app.repositories.order_repository import OrderRepository
from app.schemas.order import CreateOrderRequest
from app.telemetria import (
    pagos_confirmados,
    pedidos_cancelados,
    pedidos_creados,
    ventas_monto,
)
from app.services.exceptions import (
    DuplicateItemError,
    EmptyCartError,
    InvalidOrderStateError,
    OrderAccessDeniedError,
    OrderNotFoundError,
    ProductNotAvailableError,
)

logger = logging.getLogger(__name__)

ROLE_ADMIN = "Admin"


class Requester:
    """Quién está haciendo la petición, según lo resolvió el gateway."""

    def __init__(self, user_id: str, role: str, email: str, correlation_id: str | None) -> None:
        self.user_id = user_id
        self.role = role
        self.email = email
        self.correlation_id = correlation_id

    @property
    def is_admin(self) -> bool:
        return self.role == ROLE_ADMIN

    def to_caller(self) -> CallerContext:
        """Contexto que se propaga a los servicios que se llaman en cadena."""
        return CallerContext(
            user_id=self.user_id,
            user_role=self.role,
            correlation_id=self.correlation_id,
        )


class OrderService:
    """Orquesta el ciclo de vida del pedido."""

    def __init__(
        self,
        repository: OrderRepository,
        catalog: CatalogGateway,
        notifications: NotificationGateway,
        audit: AuditPublisher,
    ) -> None:
        self._orders = repository
        self._catalog = catalog
        self._notifications = notifications
        self._audit = audit

    # ==================================================================
    # Pasos 1 a 3 de la saga: crear el pedido
    # ==================================================================
    async def create_order(self, request: CreateOrderRequest, requester: Requester) -> Order:
        """
        Ejecuta la saga de compra completa.

        Devuelve en cuanto el pedido está en la base y el evento publicado.
        El aviso al cliente ocurre después, en otro proceso.

        Raises:
            EmptyCartError, DuplicateItemError: el carrito no es válido.
            ProductNotAvailableError: un producto no existe o está dado de baja.
            UpstreamError: el catálogo no respondió.
        """
        if not request.items:
            raise EmptyCartError("El pedido debe incluir al menos un producto")

        product_ids = [str(item.product_id) for item in request.items]
        if len(set(product_ids)) != len(product_ids):
            # Se rechaza en lugar de sumar cantidades: si el cliente mandó el
            # mismo producto dos veces, lo más probable es un error del
            # frontend, y adivinar su intención esconde el defecto.
            raise DuplicateItemError(
                "El carrito tiene el mismo producto más de una vez. "
                "Envíe un solo renglón por producto con la cantidad total."
            )

        caller = requester.to_caller()

        # ---- Paso 1: precios y disponibilidad comercial ------------------
        catalog_products = await self._catalog.get_products(product_ids, caller)

        missing = [pid for pid in product_ids if pid not in catalog_products]
        if missing:
            raise ProductNotAvailableError(
                f"Estos productos no existen en el catálogo: {', '.join(missing)}"
            )

        inactive = [pid for pid in product_ids if not catalog_products[pid].active]
        if inactive:
            names = ", ".join(catalog_products[pid].name for pid in inactive)
            raise ProductNotAvailableError(f"Estos productos ya no están a la venta: {names}")

        # ---- Paso 2: crear el pedido ------------------------------------
        order = self._build_order(request, catalog_products, requester)
        await self._orders.create(order)
        # Práctica 10: se cuenta en cuanto el pedido está en la base, que es la
        # verdad del negocio; la publicación del evento puede fallar después y
        # el pedido sigue existiendo.
        pedidos_creados.add(1, {"moneda": order.currency})

        # ---- Paso 3: publicar el evento (sin compensación) ---------------
        #
        # El orden importa y no es negociable: **primero se guarda el pedido y
        # después se publica**. Al revés, un fallo al escribir en la base
        # dejaría un evento anunciando un pedido que no existe, y el consumidor
        # avisaría al cliente de una compra fantasma. Publicar después, en
        # cambio, solo puede perder un aviso de algo que sí ocurrió: el error
        # barato de los dos.
        #
        # Queda una ventana real: si el proceso muere entre el commit y la
        # publicación, el pedido existe y nadie se entera. Cerrarla del todo
        # exige el patrón *outbox*, anotado como trabajo futuro en
        # `clients/notification_client.py`.
        await self._notify_order(order, "order_created", "Recibimos tu pedido", requester)

        await self._audit.publish(
            action="order.created",
            actor_id=requester.user_id,
            actor_role=requester.role,
            subject_type="order",
            subject_id=str(order.id),
            correlation_id=requester.correlation_id,
            data={
                "total": str(order.total),
                "currency": order.currency,
                "lines": len(order.items),
            },
        )

        return order

    # ==================================================================
    # Pago: confirma la reserva
    # ==================================================================
    async def pay_order(self, order_id: uuid.UUID, requester: Requester) -> Order:
        """
        Marca el pedido como pagado y publica el evento correspondiente.

        El estado se guarda **antes** de publicar, por el mismo motivo que en
        la creación: un evento "order.paid" de un pedido que la base no tiene
        como pagado es una contradicción que el consumidor no puede resolver,
        mientras que un pago guardado cuyo aviso se perdió es solo un correo
        que no salió.
        """
        order = await self._get_owned_order(order_id, requester)

        if order.status != OrderStatus.PENDING_PAYMENT:
            raise InvalidOrderStateError(
                f"Solo se puede pagar un pedido en estado PENDING_PAYMENT. "
                f"Este pedido está en {order.status.value}."
            )

        order.status = OrderStatus.PAID
        order.status_reason = None
        await self._orders.save(order)
        pagos_confirmados.add(1, {"moneda": order.currency})
        ventas_monto.add(float(order.total), {"moneda": order.currency})

        await self._notify_order(order, "order_paid", "Tu pago fue confirmado", requester)

        await self._audit.publish(
            action="order.paid",
            actor_id=requester.user_id,
            actor_role=requester.role,
            subject_type="order",
            subject_id=str(order.id),
            correlation_id=requester.correlation_id,
            data={"total": str(order.total), "currency": order.currency},
        )

        return order

    # ==================================================================
    # Cancelación: la compensación explícita de la saga
    # ==================================================================
    async def cancel_order(
        self, order_id: uuid.UUID, reason: str | None, requester: Requester
    ) -> Order:
        """
        Cancela un pedido pendiente.

        Solo se cancela lo que está en PENDING_PAYMENT. Un pedido pagado no se
        cancela: se reembolsa, que es otra operación con su propio registro.
        """
        order = await self._get_owned_order(order_id, requester)

        if order.status != OrderStatus.PENDING_PAYMENT:
            raise InvalidOrderStateError(
                f"Solo se puede cancelar un pedido en estado PENDING_PAYMENT. "
                f"Este pedido está en {order.status.value}."
            )

        order.status = OrderStatus.CANCELLED
        order.status_reason = reason or "Cancelado por el cliente"
        await self._orders.save(order)
        pedidos_cancelados.add(1, {"moneda": order.currency})

        await self._notify_order(order, "order_cancelled", "Tu pedido fue cancelado", requester)

        await self._audit.publish(
            action="order.cancelled",
            actor_id=requester.user_id,
            actor_role=requester.role,
            subject_type="order",
            subject_id=str(order.id),
            correlation_id=requester.correlation_id,
            data={"reason": order.status_reason},
        )

        return order

    # ==================================================================
    # Consultas
    # ==================================================================
    async def get_order(self, order_id: uuid.UUID, requester: Requester) -> Order:
        return await self._get_owned_order(order_id, requester)

    async def list_orders(
        self,
        requester: Requester,
        status: OrderStatus | None,
        limit: int,
        offset: int,
    ) -> tuple[list[Order], int]:
        """
        Historial de pedidos.

        Un Admin ve todos los del sistema; un Cliente, solo los suyos. La
        distinción está aquí, en la capa de servicio, y no en el router,
        porque es una regla de negocio y no una cuestión de transporte.
        """
        if requester.is_admin:
            return await self._orders.list_all_paginated(status, limit, offset)
        return await self._orders.list_by_user(requester.user_id, status, limit, offset)

    # ==================================================================
    # Auxiliares
    # ==================================================================
    def _build_order(
        self,
        request: CreateOrderRequest,
        catalog_products: dict,
        requester: Requester,
    ) -> Order:
        """Arma el pedido con los precios que acaba de devolver el catálogo."""
        order = Order(
            user_id=requester.user_id,
            user_email=requester.email,
            status=OrderStatus.PENDING_PAYMENT,
        )

        subtotal = Decimal("0")
        currency = "GTQ"

        for item in request.items:
            product = catalog_products[str(item.product_id)]
            line_total = product.price * item.quantity
            subtotal += line_total
            currency = product.currency

            order.items.append(
                OrderItem(
                    product_id=item.product_id,
                    sku=product.sku,
                    product_name=product.name,
                    unit_price=product.price,
                    quantity=item.quantity,
                    line_total=line_total,
                )
            )

        order.currency = currency
        order.subtotal = subtotal
        # En esta versión no hay impuestos ni envío, así que el total coincide
        # con el subtotal. Se mantienen dos columnas porque el día que se
        # agreguen, el subtotal sigue siendo el dato que la contabilidad
        # necesita y no habría que migrar la tabla.
        order.total = subtotal

        return order

    async def _get_owned_order(self, order_id: uuid.UUID, requester: Requester) -> Order:
        """
        Recupera un pedido comprobando que el solicitante pueda verlo.

        Se responde 403 y no 404 cuando el pedido existe pero es de otro
        usuario. Es discutible —un 404 no revelaría siquiera que existe— pero
        aquí los identificadores son UUID aleatorios: nadie llega a uno ajeno
        por casualidad, y un 403 le dice al desarrollador que se equivocó de
        sesión en lugar de mandarlo a buscar un pedido borrado.
        """
        order = await self._orders.get_by_id(order_id)

        if order is None:
            raise OrderNotFoundError(f"No existe el pedido {order_id}")

        if order.user_id != requester.user_id and not requester.is_admin:
            raise OrderAccessDeniedError("Este pedido pertenece a otro usuario")

        return order

    async def _notify_order(
        self, order: Order, template: str, subject: str, requester: Requester
    ) -> None:
        """
        Publica el evento del pedido. Un fallo aquí no interrumpe la compra.

        El método no sabe que detrás hay una cola: le pide a la abstracción que
        el cliente quede avisado. Si mañana el aviso vuelve a ser una llamada
        HTTP, o pasa a ser un SMS, esta función no cambia.
        """
        await self._notifications.notify(
            recipient=order.user_email,
            template=template,
            subject=subject,
            payload={
                "order_id": str(order.id),
                "status": order.status.value,
                "total": str(order.total),
                "currency": order.currency,
                "items": [
                    {
                        "name": item.product_name,
                        "quantity": item.quantity,
                        "line_total": str(item.line_total),
                    }
                    for item in order.items
                ],
            },
            caller=requester.to_caller(),
        )
