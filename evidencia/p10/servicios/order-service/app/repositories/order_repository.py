"""
order_repository.py — Principios SRP, LSP y DIP

Única responsabilidad: leer y escribir pedidos en `order_db`.

Aquí no hay reglas de negocio: este repositorio no sabe qué transiciones de
estado son válidas ni cuándo hay que liberar una reserva. Solo persiste.
"""

import uuid

from sqlalchemy import func, select
from sqlalchemy.ext.asyncio import AsyncSession

from app.models.order import Order, OrderStatus
from app.repositories.base import BaseRepository


class OrderRepository(BaseRepository[Order]):
    """Implementación del repositorio de pedidos sobre SQLAlchemy."""

    def __init__(self, session: AsyncSession) -> None:
        super().__init__(session)

    async def get_by_id(self, entity_id: uuid.UUID) -> Order | None:
        result = await self._session.execute(select(Order).where(Order.id == entity_id))
        return result.scalar_one_or_none()

    async def create(self, entity: Order) -> Order:
        self._session.add(entity)
        # `flush` envía el INSERT y asigna el id sin cerrar la transacción: la
        # saga necesita el id del pedido para reservar en inventario, pero el
        # commit todavía no debe ocurrir.
        await self._session.flush()
        await self._session.refresh(entity)
        return entity

    async def list_all(self) -> list[Order]:
        result = await self._session.execute(select(Order).order_by(Order.created_at.desc()))
        return list(result.scalars().all())

    async def list_by_user(
        self,
        user_id: str,
        status: OrderStatus | None,
        limit: int,
        offset: int,
    ) -> tuple[list[Order], int]:
        """Pedidos de un usuario, paginados, con el total para el paginador."""
        conditions = [Order.user_id == user_id]
        if status is not None:
            conditions.append(Order.status == status)

        total = await self._session.scalar(select(func.count(Order.id)).where(*conditions))

        result = await self._session.execute(
            select(Order)
            .where(*conditions)
            .order_by(Order.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        return list(result.scalars().all()), int(total or 0)

    async def list_all_paginated(
        self,
        status: OrderStatus | None,
        limit: int,
        offset: int,
    ) -> tuple[list[Order], int]:
        """Todos los pedidos del sistema. Reservado al rol Admin."""
        conditions = [Order.status == status] if status is not None else []

        total = await self._session.scalar(select(func.count(Order.id)).where(*conditions))

        result = await self._session.execute(
            select(Order)
            .where(*conditions)
            .order_by(Order.created_at.desc())
            .limit(limit)
            .offset(offset)
        )
        return list(result.scalars().all()), int(total or 0)

    async def save(self, order: Order) -> Order:
        """Persiste los cambios de un pedido ya existente en la sesión."""
        await self._session.flush()
        await self._session.refresh(order)
        return order
