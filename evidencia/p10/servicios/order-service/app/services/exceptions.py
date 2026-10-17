"""
exceptions.py — Principio SRP

Excepciones de dominio de order-service.

La capa de servicio nunca lanza `HTTPException`: lanza errores de negocio y es
el router quien los traduce a códigos HTTP. Así el servicio se puede reutilizar
desde un worker, un comando de consola o una prueba, sin arrastrar FastAPI.
"""



class DomainError(Exception):
    """Error de negocio genérico."""


class EmptyCartError(DomainError):
    """El pedido llegó sin renglones."""


class DuplicateItemError(DomainError):
    """El mismo producto aparece dos veces en el carrito."""


class ProductNotAvailableError(DomainError):
    """Un producto del carrito no existe o fue dado de baja."""


class OrderNotFoundError(DomainError):
    """El pedido no existe."""


class OrderAccessDeniedError(DomainError):
    """El pedido existe, pero es de otro usuario."""


class InvalidOrderStateError(DomainError):
    """La operación no es válida en el estado actual del pedido."""
