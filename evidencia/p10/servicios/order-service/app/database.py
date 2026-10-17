"""
database.py — Principio SRP

Única responsabilidad: gestionar la conexión a `order_db` mediante SQLAlchemy
async. Expone el engine, la fábrica de sesiones, la clase Base y la dependencia
`get_db`.
"""

from collections.abc import AsyncGenerator

from sqlalchemy.ext.asyncio import AsyncSession, async_sessionmaker, create_async_engine
from sqlalchemy.orm import DeclarativeBase

from app.config import settings

engine = create_async_engine(
    settings.database_url,
    echo=False,
    # Comprueba que la conexión siga viva antes de entregarla. Sin esto, tras
    # un reinicio de PostgreSQL el pool serviría conexiones muertas y el primer
    # request de cada una fallaría.
    pool_pre_ping=True,
    pool_size=10,
    max_overflow=20,
)

AsyncSessionFactory = async_sessionmaker(
    bind=engine,
    expire_on_commit=False,
    autoflush=False,
    autocommit=False,
)


class Base(DeclarativeBase):
    """Clase base de todos los modelos de order-service."""


async def create_tables() -> None:
    """Crea las tablas al arrancar si aún no existen."""
    from app.models.order import Order, OrderItem  # noqa: F401

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


async def get_db() -> AsyncGenerator[AsyncSession, None]:
    """Provee una sesión por request, con commit al terminar y rollback si falla."""
    async with AsyncSessionFactory() as session:
        try:
            yield session
            await session.commit()
        except Exception:
            await session.rollback()
            raise
        finally:
            await session.close()
