"""
catalog_client.py — Principios SRP, ISP y DIP

Única responsabilidad: obtener del catálogo los datos de los productos que se
están comprando.

ISP: la interfaz `CatalogGateway` declara **un solo método**. `order-service`
no necesita crear productos ni listar categorías, así que no depende de una
interfaz que ofrezca esas operaciones. Depender de lo mínimo significa que un
cambio en la parte del catálogo que no usamos no nos obliga a recompilar nada.

Nótese lo que pide la consulta GraphQL: `id sku name price currency active`, y
nada más. No trae descripción, ni imagen, ni la categoría anidada. En REST
recibiríamos el objeto completo de diez productos aunque solo usemos seis
campos; con GraphQL el ahorro es explícito y está a la vista en el código.
"""

from abc import ABC, abstractmethod
from dataclasses import dataclass
from decimal import Decimal

from app.clients.graphql_client import CallerContext, GraphQLClient

PRODUCTS_BY_IDS = """
query ProductsForCheckout($ids: [ID!]!) {
  productsByIds(ids: $ids) {
    id
    sku
    name
    price
    currency
    active
  }
}
"""


@dataclass(frozen=True)
class CatalogProduct:
    """Fotografía de un producto en el momento de la compra."""

    id: str
    sku: str
    name: str
    price: Decimal
    currency: str
    active: bool


class CatalogGateway(ABC):
    """Lo único que order-service necesita del catálogo."""

    @abstractmethod
    async def get_products(
        self, product_ids: list[str], caller: CallerContext
    ) -> dict[str, CatalogProduct]:
        """Devuelve los productos indexados por id. Los inexistentes no aparecen."""


class GraphQLCatalogClient(GraphQLClient, CatalogGateway):
    """Implementación contra el endpoint GraphQL de catalog-service."""

    @property
    def service_name(self) -> str:
        return "catalog-service"

    async def get_products(
        self, product_ids: list[str], caller: CallerContext
    ) -> dict[str, CatalogProduct]:
        if not product_ids:
            return {}

        data = await self.execute(PRODUCTS_BY_IDS, {"ids": product_ids}, caller)

        return {
            item["id"]: CatalogProduct(
                id=item["id"],
                sku=item["sku"],
                name=item["name"],
                # El precio llega como número JSON. Se convierte a Decimal
                # pasando por str: `Decimal(12999.0)` arrastraría el error del
                # flotante, `Decimal("12999.0")` no.
                price=Decimal(str(item["price"])),
                currency=item["currency"],
                active=item["active"],
            )
            for item in data.get("productsByIds", [])
        }
