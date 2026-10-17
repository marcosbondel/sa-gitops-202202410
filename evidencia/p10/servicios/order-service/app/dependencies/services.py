"""
services.py (dependencies) — Principio DIP

Única responsabilidad: construir e inyectar los servicios de la aplicación.

Este es el *composition root*: el único lugar donde se decide qué
implementación concreta recibe cada abstracción.

## El cambio de la Práctica 4 a la 5, en dos líneas

Este archivo es donde el sistema pasó de síncrono a asíncrono, y es útil verlo
en concreto:

    # Práctica 4 — el checkout esperaba a que el aviso se registrara
    notification_gateway = HttpNotificationClient(...)

    # Práctica 5 — el checkout publica el evento y retorna
    notification_gateway = BrokerNotificationPublisher(...)

`OrderService` no cambió. Los routers no cambiaron. La saga no cambió. Esa es
la promesa que hace el principio de inversión de dependencias cuando uno la
escribe antes de necesitarla: el día que el detalle cambia, el cambio queda
contenido en el archivo que existe justamente para eso.
"""

from typing import Annotated

from fastapi import Depends
from sqlalchemy.ext.asyncio import AsyncSession

from app.clients.audit_client import AuditPublisher, NullAuditPublisher
from app.clients.catalog_client import CatalogGateway, GraphQLCatalogClient
from app.clients.notification_client import BrokerNotificationPublisher, NotificationGateway
from app.config import settings
from app.database import get_db
from app.repositories.order_repository import OrderRepository
from app.services.order_service import OrderService

DbSession = Annotated[AsyncSession, Depends(get_db)]

# El cliente del catálogo no guarda estado entre peticiones (abre y cierra su
# conexión HTTP en cada llamada), así que se construye una sola vez al importar
# el módulo en lugar de instanciarlo por request.
catalog_gateway: CatalogGateway = GraphQLCatalogClient(
    base_url=settings.catalog_service_url,
    service_name="catalog-service",
    timeout_seconds=settings.upstream_timeout_seconds,
)

# El publicador sí guarda estado —la conexión con el broker— y por eso es un
# singleton de verdad: abrir una conexión AMQP por petición desperdiciaría el
# handshake y saturaría al broker de conexiones efímeras. `main.py` la cierra
# al apagar el servicio.
notification_gateway: NotificationGateway = BrokerNotificationPublisher(
    amqp_url=settings.amqp_url,
    exchange_name=settings.rabbitmq_exchange,
    publish_timeout_seconds=settings.publish_timeout_seconds,
)

# audit-service quedó fuera del alcance de la Práctica 5 (cuatro microservicios
# más el gateway). El puerto `AuditPublisher` se conserva porque describe una
# necesidad real del dominio —dejar constancia de lo que ocurre— y se inyecta
# la implementación nula. Cuando la bitácora vuelva, será una línea aquí y
# ningún cambio en `OrderService`; borrar la abstracción habría convertido ese
# regreso en una modificación de la capa de negocio.
audit_publisher: AuditPublisher = NullAuditPublisher()


def get_order_service(session: DbSession) -> OrderService:
    """Arma el OrderService con sus cuatro colaboradores."""
    return OrderService(
        repository=OrderRepository(session),
        catalog=catalog_gateway,
        notifications=notification_gateway,
        audit=audit_publisher,
    )


OrderServiceDep = Annotated[OrderService, Depends(get_order_service)]
