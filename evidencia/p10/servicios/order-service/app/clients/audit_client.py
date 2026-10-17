"""
audit_client.py — Principios SRP y DIP

Responsabilidad única: enviar eventos de bitácora a `audit-service`.

Es un ejemplo de **comunicación directa entre microservicios**, sin pasar por
el gateway: order-service llama a audit-service por el DNS interno de Docker.

Dos decisiones de diseño explícitas:

1. **Es "fire and forget".** Registrar la bitácora nunca puede hacer fallar un
   login. Si audit-service está caído, se anota el problema en el log local y
   la petición del usuario continúa. La alternativa —propagar el error— haría
   que la caída de un servicio secundario tumbara el checkout completo.

2. **Se define la interfaz `AuditPublisher`.** La capa de servicio depende de
   la abstracción, no de HTTP (DIP). En las pruebas se inyecta
   `NullAuditPublisher` y no hace falta levantar nada.
"""

import logging
from abc import ABC, abstractmethod
from datetime import UTC, datetime
from typing import Any

import httpx

logger = logging.getLogger(__name__)

# Un evento de bitácora no debe hacer esperar al usuario: si audit-service no
# responde en 2 segundos, se abandona el intento.
AUDIT_TIMEOUT_SECONDS = 2.0


class AuditPublisher(ABC):
    """Abstracción de un destino de eventos de auditoría."""

    @abstractmethod
    async def publish(
        self,
        *,
        action: str,
        actor_id: str | None = None,
        actor_role: str | None = None,
        subject_type: str | None = None,
        subject_id: str | None = None,
        correlation_id: str | None = None,
        data: dict[str, Any] | None = None,
    ) -> None:
        """Registra un hecho ocurrido en el servicio."""
        raise NotImplementedError


class HttpAuditPublisher(AuditPublisher):
    """Implementación que publica por HTTP contra audit-service."""

    def __init__(self, base_url: str, service_name: str) -> None:
        self._base_url = base_url.rstrip("/")
        self._service_name = service_name

    async def publish(
        self,
        *,
        action: str,
        actor_id: str | None = None,
        actor_role: str | None = None,
        subject_type: str | None = None,
        subject_id: str | None = None,
        correlation_id: str | None = None,
        data: dict[str, Any] | None = None,
    ) -> None:
        payload = {
            "service": self._service_name,
            "action": action,
            "occurred_at": datetime.now(UTC).isoformat(),
            "actor_id": actor_id,
            "actor_role": actor_role,
            "subject_type": subject_type,
            "subject_id": subject_id,
            "correlation_id": correlation_id,
            "data": data or {},
        }
        try:
            async with httpx.AsyncClient(timeout=AUDIT_TIMEOUT_SECONDS) as client:
                await client.post(f"{self._base_url}/api/audit/events", json=payload)
        except httpx.HTTPError as error:
            # Degradación controlada: se pierde el evento, no la operación.
            logger.warning("No se pudo registrar el evento '%s' en la bitácora: %s", action, error)


class NullAuditPublisher(AuditPublisher):
    """Implementación vacía para pruebas y ejecución sin audit-service."""

    async def publish(self, **_: Any) -> None:
        return None
