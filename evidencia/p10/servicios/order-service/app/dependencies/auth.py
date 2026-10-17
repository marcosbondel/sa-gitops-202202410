"""
auth.py (dependencies) — Principios SRP, OCP y DIP

Única responsabilidad: resolver quién está haciendo la petición.

## De dónde sale la identidad y por qué se puede confiar en ella

`order-service` **no valida JWT**. Cuando la petición llega hasta aquí, el API
Gateway ya consultó a `auth-service` (`POST /api/auth/introspect`), comprobó la
firma y la vigencia del token, resolvió el usuario contra la base de usuarios e
inyectó el resultado en tres cabeceras:

    X-User-Id        identificador del usuario
    X-User-Role      rol vigente, leído de la base y no del token
    X-User-Email     correo, que este servicio usa para notificar

La confianza se apoya en dos hechos, no en buena fe:

  1. El gateway **borra** esas cabeceras si vienen del cliente antes de
     escribir las suyas (ver gateway/src/middleware/authenticate.ts). Nadie
     puede declararse Admin mandando un encabezado.
  2. Este servicio vive en una red interna de Docker. La única ruta desde
     internet pasa por el gateway.

En un despliegue productivo se añadiría una tercera capa —mTLS entre gateway y
servicios, o una malla de servicios— para que la propiedad se sostenga aunque
alguien logre entrar a la red. Se documenta como límite conocido de esta
entrega.

La ventaja de este diseño es concreta: la llave del JWT existe en un solo
servicio. Rotarla no obliga a redesplegar los otros cinco.
"""

from typing import Annotated

from fastapi import Depends, Header, HTTPException, status

from app.services.order_service import ROLE_ADMIN, Requester


async def get_requester(
    x_user_id: Annotated[str | None, Header()] = None,
    x_user_role: Annotated[str | None, Header()] = None,
    x_user_email: Annotated[str | None, Header()] = None,
    x_correlation_id: Annotated[str | None, Header()] = None,
) -> Requester:
    """
    Construye el `Requester` a partir de las cabeceras inyectadas por el gateway.

    Que falten significa que alguien llegó por un camino que no es el gateway
    —normalmente, llamando al puerto del servicio directamente durante una
    prueba—. Se responde 401 en lugar de asumir un usuario anónimo: un servicio
    de pedidos sin saber de quién es el pedido no tiene nada que hacer.
    """
    if not x_user_id:
        raise HTTPException(
            status_code=status.HTTP_401_UNAUTHORIZED,
            detail=(
                "No se recibió la identidad del usuario. Las peticiones deben "
                "entrar por el API Gateway (http://localhost:8080/api/orders)."
            ),
        )

    return Requester(
        user_id=x_user_id,
        role=x_user_role or "Cliente",
        # El correo puede faltar si el gateway aún no lo propaga; se usa un
        # marcador antes que dejar el pedido sin destinatario de notificación.
        email=x_user_email or f"usuario-{x_user_id}@tienda.local",
        correlation_id=x_correlation_id,
    )


CurrentRequester = Annotated[Requester, Depends(get_requester)]


async def require_admin(requester: CurrentRequester) -> Requester:
    """
    Guarda de autorización para las rutas exclusivas de administración.

    Se separa de `get_requester` a propósito: la autenticación responde *quién
    sos* y la autorización *qué podés hacer*. Mantenerlas aparte permite que un
    endpoint exija identidad sin exigir un rol concreto.
    """
    if not requester.is_admin:
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                f"Acceso denegado. El rol '{requester.role}' no tiene permiso "
                f"sobre este recurso. Se requiere el rol {ROLE_ADMIN}."
            ),
        )
    return requester


AdminRequester = Annotated[Requester, Depends(require_admin)]
