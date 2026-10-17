/**
 * typeDefs.ts — Principio SRP
 *
 * Única responsabilidad: declarar el esquema GraphQL, que es **el contrato
 * público de este microservicio**.
 *
 * ## Por qué GraphQL aquí y no REST
 *
 * El catálogo es el servicio con más consumidores distintos y con más formas
 * de la misma consulta: la vitrina quiere nombre, precio e imagen; el buscador
 * quiere nombre y categoría; `order-service` solo quiere precio y SKU de diez
 * ids concretos. En REST eso termina en `/products?fields=...` o en tres
 * endpoints casi iguales. Con GraphQL cada consumidor pide exactamente los
 * campos que va a usar contra un solo endpoint, y agregar un campo nuevo no
 * rompe a nadie porque nadie recibe lo que no pidió.
 */

export const typeDefs = /* GraphQL */ `
  """
  Estado del microservicio. Lo consulta el gateway en su agregado /health.
  """
  type ServiceHealth {
    status: String!
    service: String!
    language: String!
    api: String!
    version: String!
    products: Int!
  }

  "Agrupación comercial de productos."
  type Category {
    id: ID!
    name: String!
    slug: String!
    description: String
    "Productos activos de la categoría. Se resuelve solo si el cliente lo pide."
    products: [Product!]!
    createdAt: String!
  }

  "Artículo a la venta."
  type Product {
    id: ID!
    "Código interno único e inmutable del artículo."
    sku: String!
    name: String!
    description: String
    price: Float!
    "Código ISO 4217. La tienda opera en quetzales."
    currency: String!
    imageUrl: String
    "False cuando el producto fue dado de baja; sigue existiendo para el historial de pedidos."
    active: Boolean!
    category: Category
    createdAt: String!
    updatedAt: String!
  }

  "Página de resultados. Se devuelve el total para que el cliente pueda pintar el paginador."
  type ProductPage {
    items: [Product!]!
    total: Int!
    limit: Int!
    offset: Int!
  }

  "Todos los campos son opcionales: se combinan los que el cliente envíe."
  input ProductFilter {
    "Coincidencia parcial sobre nombre o SKU."
    search: String
    categorySlug: String
    minPrice: Float
    maxPrice: Float
    "Por defecto true. Solo un Admin tiene motivo para ponerlo en false."
    activeOnly: Boolean
  }

  input CreateProductInput {
    sku: String!
    name: String!
    description: String
    price: Float!
    currency: String
    categoryId: ID
    imageUrl: String
  }

  input UpdateProductInput {
    name: String
    description: String
    price: Float
    categoryId: ID
    imageUrl: String
    active: Boolean
  }

  type Query {
    health: ServiceHealth!

    "Listado paginado y filtrable. Es la consulta de la vitrina."
    products(filter: ProductFilter, limit: Int = 20, offset: Int = 0): ProductPage!

    product(id: ID!): Product

    """
    Varios productos en una sola consulta.
    La usa order-service durante el checkout para traer precio y nombre de
    todas las líneas del carrito sin hacer una llamada por artículo.
    """
    productsByIds(ids: [ID!]!): [Product!]!

    categories: [Category!]!
    category(slug: String!): Category
  }

  type Mutation {
    "Requiere rol Admin."
    createProduct(input: CreateProductInput!): Product!

    "Requiere rol Admin. Actualización parcial: lo que no se envía no se toca."
    updateProduct(id: ID!, input: UpdateProductInput!): Product!

    "Requiere rol Admin. Baja lógica: el producto queda inactivo, no se borra."
    deleteProduct(id: ID!): Boolean!

    "Requiere rol Admin."
    createCategory(name: String!, slug: String!, description: String): Category!
  }
`;
