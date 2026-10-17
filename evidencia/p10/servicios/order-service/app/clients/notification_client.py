"""
notification_client.py — Principios SRP, ISP, DIP y LSP

Única responsabilidad: hacerle llegar al resto del sistema el hecho de que un
pedido cambió de estado.

## El cambio central de esta práctica

En la Práctica 4 este archivo contenía `HttpNotificationClient`: order-service
llamaba por HTTP a notification-service, esperaba su respuesta y solo entonces
le contestaba al cliente. Era una llamada **síncrona** y acoplaba en el tiempo
a dos servicios que no tienen por qué estarlo.

Aquí la implementación es `BrokerNotificationPublisher`: publica un evento en
RabbitMQ y retorna. Lo que ocurre después —armar el mensaje, guardarlo,
intentar el envío— sucede en otro proceso, cuando ese proceso pueda.

Lo que **no** cambió es la interfaz. `NotificationGateway` es exactamente la
misma abstracción que en la Práctica 4, y `OrderService` no tiene una sola
línea distinta por este motivo: sigue llamando `notifications.notify(...)` sin
saber si detrás hay un socket HTTP o una cola. Cambiar de síncrono a asíncrono
fue sustituir una implementación en el composition root.

Eso es DIP y LSP funcionando juntos, y es la razón por la que valió la pena
escribir la abstracción cuando parecía innecesaria: la política de alto nivel
("al crear un pedido hay que avisar") no dependía del detalle ("por HTTP"), y
el detalle se pudo cambiar entero sin tocarla.

## Qué se gana y qué se paga

Se gana:
  · El checkout deja de depender de que notification-service esté vivo. Si el
    consumidor está caído, el mensaje espera en la cola; el cliente ya tiene su
    pedido.
  · El tiempo de respuesta del checkout deja de incluir el de la notificación.
  · Los picos se absorben: la cola crece y el consumidor la drena a su ritmo,
    en lugar de que order-service se quede esperando.

Se paga:
  · **Consistencia eventual.** Justo después del checkout, la notificación
    puede no existir todavía. La API tiene que poder decir "aún no" en lugar
    de mentir.
  · **Entrega "al menos una vez".** Si el consumidor procesa un mensaje y
    muere antes de confirmarlo, RabbitMQ lo reentrega. El consumidor tiene que
    ser idempotente; ver `app/worker.py` en notification-service.
  · **Un componente más que puede fallar**, y que hay que operar: colas que
    crecen, mensajes que nadie consume, memoria del broker.

## Por qué la publicación es "best effort"

Un fallo al publicar no revierte el pedido, igual que antes un fallo del HTTP
no lo revertía. El pedido ya está en la base y es la verdad del negocio; el
aviso es un efecto secundario. La alternativa correcta y más cara es el patrón
*outbox* —escribir el evento en la misma transacción del pedido y que un
proceso aparte lo publique—, que garantiza que no se pierda ningún evento.
Queda anotado como el siguiente paso, y fuera del alcance de esta práctica.
"""

import asyncio
import json
import logging
from abc import ABC, abstractmethod
from datetime import UTC, datetime
from typing import Any

import aio_pika
from aio_pika.abc import AbstractRobustConnection

from app.clients.graphql_client import CallerContext

logger = logging.getLogger(__name__)


class NotificationGateway(ABC):
    """
    Lo único que order-service necesita del servicio de notificaciones.

    ISP: la interfaz tiene un método. `OrderService` no puede consultar
    bandejas ni reintentar envíos porque no le corresponde y, al no estar
    declarado aquí, ni siquiera es capaz de intentarlo.
    """

    @abstractmethod
    async def notify(
        self,
        *,
        recipient: str,
        template: str,
        subject: str,
        payload: dict[str, Any],
        caller: CallerContext,
    ) -> bool:
        """Da por avisado al cliente. Devuelve False si no se pudo encolar."""


class BrokerNotificationPublisher(NotificationGateway):
    """
    Publica el evento del pedido en RabbitMQ.

    ## Decisiones de durabilidad

    Tres cosas tienen que ser duraderas para que un mensaje sobreviva a un
    reinicio del broker, y las tres están aquí o en el consumidor:

      1. **El exchange es `durable=True`** — sobrevive al reinicio del broker.
      2. **El mensaje es `PERSISTENT`** — RabbitMQ lo escribe a disco antes de
         confirmarlo, en lugar de dejarlo solo en memoria.
      3. **La cola es `durable=True`** — la declara el consumidor
         (`app/worker.py` de notification-service).

    Faltando cualquiera de las tres, un `kubectl delete pod` del broker se
    llevaría los mensajes por delante. Marcar el mensaje como persistente y
    dejar la cola transitoria es el error más común: parece configurado y no
    lo está.

    ## Por qué un exchange `topic` y no publicar directo a la cola

    Publicar a una cola por nombre acopla al productor con sus consumidores:
    agregar un segundo interesado en `order.created` obligaría a cambiar
    order-service. Con un exchange topic, order-service solo anuncia "pasó
    esto"; quién escucha es decisión de quien escucha, expresada con un
    binding. Es el mismo OCP del gateway, aplicado a la mensajería.

    ## Por qué `connect_robust`

    Devuelve una conexión que se reconecta sola. En Kubernetes esto no es un
    lujo: el pod del broker se reinicia en cada `helm upgrade` que lo toque, y
    sin reconexión automática los productores quedarían inútiles hasta que
    alguien los reiniciara a mano.
    """

    def __init__(
        self,
        *,
        amqp_url: str,
        exchange_name: str,
        publish_timeout_seconds: float,
    ) -> None:
        self._amqp_url = amqp_url
        self._exchange_name = exchange_name
        self._timeout = publish_timeout_seconds
        self._connection: AbstractRobustConnection | None = None
        # Varias peticiones concurrentes pueden encontrar la conexión cerrada a
        # la vez. Sin este candado, cada una abriría la suya y el servicio
        # acabaría con tantas conexiones al broker como peticiones en vuelo.
        self._lock = asyncio.Lock()

    async def _get_connection(self) -> AbstractRobustConnection:
        """Devuelve la conexión compartida, abriéndola la primera vez."""
        if self._connection is not None and not self._connection.is_closed:
            return self._connection

        async with self._lock:
            # Se vuelve a comprobar dentro del candado: mientras esta corrutina
            # esperaba, otra pudo haber abierto ya la conexión.
            if self._connection is None or self._connection.is_closed:
                self._connection = await aio_pika.connect_robust(self._amqp_url)
                logger.info("Conexión con el broker establecida")

        return self._connection

    async def notify(
        self,
        *,
        recipient: str,
        template: str,
        subject: str,
        payload: dict[str, Any],
        caller: CallerContext,
    ) -> bool:
        # La clave de enrutamiento se deriva de la plantilla: "order_created"
        # se publica como "order.created". Un consumidor puede así atarse a
        # `order.*` y recibirlos todos, o a `order.cancelled` y recibir uno.
        routing_key = f"order.{template.removeprefix('order_')}"

        event = {
            # Versión del contrato del mensaje. Sin esto, cambiar la forma del
            # evento obliga a desplegar productor y consumidor a la vez, que es
            # exactamente el acoplamiento que la cola vino a romper.
            "event_version": 1,
            "event_type": routing_key,
            "occurred_at": datetime.now(UTC).isoformat(),
            # El hilo de la traza cruza el salto asíncrono dentro del mensaje.
            "correlation_id": caller.correlation_id,
            "requested_by": caller.user_id,
            "recipient": recipient,
            "template": template,
            "subject": subject,
            "payload": payload,
        }

        try:
            connection = await self._get_connection()
            channel = await connection.channel()
            try:
                exchange = await channel.declare_exchange(
                    self._exchange_name,
                    aio_pika.ExchangeType.TOPIC,
                    durable=True,
                )
                await asyncio.wait_for(
                    exchange.publish(
                        aio_pika.Message(
                            body=json.dumps(event).encode("utf-8"),
                            content_type="application/json",
                            delivery_mode=aio_pika.DeliveryMode.PERSISTENT,
                            correlation_id=caller.correlation_id,
                            # `message_id` es lo que le permite al consumidor
                            # reconocer una reentrega y no duplicar el aviso.
                            message_id=f"{payload.get('order_id')}:{routing_key}",
                            type=routing_key,
                        ),
                        routing_key=routing_key,
                    ),
                    timeout=self._timeout,
                )
            finally:
                await channel.close()

            logger.info(
                "Evento '%s' publicado para el pedido %s",
                routing_key,
                payload.get("order_id"),
            )
            return True

        except (aio_pika.exceptions.AMQPError, asyncio.TimeoutError, OSError) as error:
            # Degradación controlada: se pierde el aviso, no la compra. Se
            # registra en WARNING y no en ERROR porque el sistema sigue
            # correcto; lo que se perdió es un efecto secundario.
            logger.warning(
                "No se pudo publicar el evento '%s' para %s: %s", routing_key, recipient, error
            )
            return False

    async def close(self) -> None:
        """Cierra la conexión al apagar el servicio."""
        if self._connection is not None and not self._connection.is_closed:
            await self._connection.close()
            logger.info("Conexión con el broker cerrada")


class NullNotificationPublisher(NotificationGateway):
    """
    No publica nada. Se usa en pruebas, donde levantar un broker sería absurdo.

    Existe por LSP: `OrderService` funciona igual con esta implementación que
    con la real, porque la única promesa del contrato —"devuelve si se pudo
    encolar"— se cumple en ambas.
    """

    async def notify(self, **_: Any) -> bool:
        return True
