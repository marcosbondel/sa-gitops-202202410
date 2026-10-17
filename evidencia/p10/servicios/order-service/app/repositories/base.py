"""
repositories/base.py — Principios OCP, LSP y DIP

Interfaz abstracta genérica del patrón Repository.

OCP: para agregar una entidad nueva se crea otra subclase; este archivo no se
     modifica.
LSP: cualquier implementación concreta de `BaseRepository[T]` puede sustituir a
     otra —por ejemplo, una en memoria durante las pruebas— sin que el servicio
     que la consume deje de funcionar.
DIP: los servicios dependen de esta abstracción y no de SQLAlchemy.
"""

import uuid
from abc import ABC, abstractmethod
from typing import Generic, TypeVar

from sqlalchemy.ext.asyncio import AsyncSession

T = TypeVar("T")


class BaseRepository(ABC, Generic[T]):
    """Repositorio base con las operaciones comunes de persistencia."""

    def __init__(self, session: AsyncSession) -> None:
        self._session = session

    @abstractmethod
    async def get_by_id(self, entity_id: uuid.UUID) -> T | None:
        """Busca un registro por su identificador."""

    @abstractmethod
    async def create(self, entity: T) -> T:
        """Persiste una entidad nueva."""

    @abstractmethod
    async def list_all(self) -> list[T]:
        """Retorna todos los registros de la entidad."""
