"""
graphql_client.py — Principios SRP y DIP

Única responsabilidad: hablar GraphQL por HTTP con otro microservicio.

Es la base común de `CatalogClient` e `InventoryClient`. Que exista aquí y no
duplicada en cada cliente es lo que evita que dentro de un mes uno de los dos
maneje los errores de una forma y el otro de otra.

## Propagación de identidad

Cada llamada reenvía `X-User-Id`, `X-User-Role` y `X-Correlation-Id`. Es la
pieza que hace que la cadena funcione: cuando `order-service` reserva
existencias, lo hace **en nombre del cliente que está comprando**, y el
inventario ve al comprador, no a un servicio anónimo. Si esas cabeceras se
perdieran, cada servicio intermedio tendría que inventarse un usuario de
sistema con permisos amplios, que es exactamente el patrón que produce
escaladas de privilegio.
"""

import logging
from abc import ABC, abstractmethod
from dataclasses import dataclass
from typing import Any

import httpx

logger = logging.getLogger(__name__)


@dataclass(frozen=True)
class CallerContext:
    """Identidad del usuario en cuyo nombre se hace la llamada."""

    user_id: str | None = None
    user_role: str | None = None
    correlation_id: str | None = None

    def to_headers(self) -> dict[str, str]:
        headers: dict[str, str] = {}
        if self.user_id:
            headers["X-User-Id"] = self.user_id
        if self.user_role:
            headers["X-User-Role"] = self.user_role
        if self.correlation_id:
            headers["X-Correlation-Id"] = self.correlation_id
        return headers


class UpstreamError(Exception):
    """
    Un microservicio del que dependemos falló.

    Se distingue de los errores de negocio a propósito: "no hay existencias" es
    una respuesta legítima que el usuario entiende, mientras que "el inventario
    no contesta" es un problema de infraestructura que amerita un 503 y una
    alerta. Mezclarlos haría que una caída se le reportara al cliente como si
    hubiera hecho algo mal.
    """

    def __init__(self, service: str, detail: str) -> None:
        super().__init__(f"{service}: {detail}")
        self.service = service
        self.detail = detail


class GraphQLClient(ABC):
    """Cliente GraphQL genérico sobre httpx."""

    def __init__(self, base_url: str, service_name: str, timeout_seconds: float) -> None:
        self._endpoint = f"{base_url.rstrip('/')}/graphql"
        self._service_name = service_name
        self._timeout = timeout_seconds

    @property
    @abstractmethod
    def service_name(self) -> str:
        """Nombre del servicio, para los mensajes de error."""

    async def execute(
        self,
        query: str,
        variables: dict[str, Any],
        caller: CallerContext,
    ) -> dict[str, Any]:
        """
        Ejecuta una operación GraphQL y devuelve el bloque `data`.

        Raises:
            UpstreamError: si el servicio no responde, responde con un código
                de error HTTP, o devuelve errores en el campo `errors`.
        """
        payload = {"query": query, "variables": variables}

        try:
            async with httpx.AsyncClient(timeout=self._timeout) as client:
                response = await client.post(
                    self._endpoint,
                    json=payload,
                    headers={"Content-Type": "application/json", **caller.to_headers()},
                )
        except httpx.HTTPError as error:
            # Práctica 10: aquí está la causa, con todo lo necesario para
            # entenderla sin abrir el código —a qué URL, con qué plazo y qué
            # contestó la red—. El `trace_id` lo pone el formateador.
            logger.error(
                "llamada a %s fallida: no respondió",
                self._service_name,
                extra={
                    "upstream.service": self._service_name,
                    "url.full": self._endpoint,
                    "timeout_s": self._timeout,
                    "error.type": type(error).__name__,
                    "error.message": str(error) or repr(error),
                },
            )
            raise UpstreamError(self._service_name, f"no respondió ({type(error).__name__})") from error

        if response.status_code >= 400:
            raise UpstreamError(
                self._service_name, f"respondió con estado HTTP {response.status_code}"
            )

        body = response.json()

        # GraphQL devuelve 200 aunque la operación haya fallado: el error viaja
        # en el campo `errors` del cuerpo. Revisar solo el código HTTP dejaría
        # pasar fallos silenciosamente con `data` en null.
        if body.get("errors"):
            messages = "; ".join(
                str(error.get("message", "error desconocido")) for error in body["errors"]
            )
            raise UpstreamError(self._service_name, messages)

        data = body.get("data")
        if data is None:
            raise UpstreamError(self._service_name, "respondió sin datos")

        return data
