/**
 * resolvers.ts — Principios SRP y DIP
 *
 * Única responsabilidad: conectar el esquema GraphQL con la capa de servicio.
 *
 * Los resolvers son deliberadamente delgados: validan permisos, delegan y
 * adaptan el resultado. Toda regla de negocio vive en `CatalogService`. Si
 * mañana el catálogo se expusiera además por REST o por gRPC, esa capa se
 * reutilizaría entera y solo se escribiría otro adaptador como este.
 */

import { GraphQLError } from 'graphql';
import { config } from '../config';
import { DomainError } from '../errors';
import type { Category, Product } from '../types';
import { requireAdmin, type GraphQLContext } from './context';

/**
 * Traduce un error de dominio a un error GraphQL con su código.
 *
 * Sin esto, Apollo devolvería `INTERNAL_SERVER_ERROR` para todo y el cliente
 * no podría distinguir "no existe" de "no tenés permiso" de "se cayó la base".
 */
function toGraphQLError(error: unknown): never {
  if (error instanceof DomainError) {
    throw new GraphQLError(error.message, { extensions: { code: error.code } });
  }
  throw error;
}

/** GraphQL no tiene tipo fecha nativo; se serializa en ISO 8601 (UTC). */
function iso(value: Date): string {
  return value.toISOString();
}

export const resolvers = {
  Query: {
    health: async (_parent: unknown, _args: unknown, context: GraphQLContext) => {
      const page = await context.catalog.listProducts({ activeOnly: false }, 1, 0);
      return {
        status: 'ok',
        service: config.serviceName,
        language: config.language,
        api: config.api,
        version: config.version,
        products: page.total,
      };
    },

    products: async (
      _parent: unknown,
      args: { filter?: Parameters<GraphQLContext['catalog']['listProducts']>[0]; limit: number; offset: number },
      context: GraphQLContext,
    ) => context.catalog.listProducts(args.filter, args.limit ?? 20, args.offset ?? 0),

    product: async (_parent: unknown, args: { id: string }, context: GraphQLContext) =>
      context.catalog.getProduct(args.id),

    productsByIds: async (_parent: unknown, args: { ids: string[] }, context: GraphQLContext) =>
      context.catalog.getProductsByIds(args.ids),

    categories: async (_parent: unknown, _args: unknown, context: GraphQLContext) =>
      context.catalog.listCategories(),

    category: async (_parent: unknown, args: { slug: string }, context: GraphQLContext) =>
      context.catalog.getCategoryBySlug(args.slug),
  },

  Mutation: {
    createProduct: async (
      _parent: unknown,
      args: { input: Parameters<GraphQLContext['catalog']['createProduct']>[0] },
      context: GraphQLContext,
    ) => {
      const actor = requireAdmin(context);
      try {
        return await context.catalog.createProduct(args.input, actor);
      } catch (error) {
        toGraphQLError(error);
      }
    },

    updateProduct: async (
      _parent: unknown,
      args: { id: string; input: Parameters<GraphQLContext['catalog']['updateProduct']>[1] },
      context: GraphQLContext,
    ) => {
      const actor = requireAdmin(context);
      try {
        return await context.catalog.updateProduct(args.id, args.input, actor);
      } catch (error) {
        toGraphQLError(error);
      }
    },

    deleteProduct: async (_parent: unknown, args: { id: string }, context: GraphQLContext) => {
      const actor = requireAdmin(context);
      try {
        return await context.catalog.deleteProduct(args.id, actor);
      } catch (error) {
        toGraphQLError(error);
      }
    },

    createCategory: async (
      _parent: unknown,
      args: { name: string; slug: string; description?: string | null },
      context: GraphQLContext,
    ) => {
      const actor = requireAdmin(context);
      try {
        return await context.catalog.createCategory(
          args.name,
          args.slug,
          args.description ?? null,
          actor,
        );
      } catch (error) {
        toGraphQLError(error);
      }
    },
  },

  // Resolvers de campo: solo se ejecutan si el cliente pide ese campo.
  // Consultar los productos de la vitrina no toca la tabla de categorías a
  // menos que la consulta incluya `category { ... }`. Es la ventaja concreta
  // de GraphQL frente a un REST que siempre devuelve el objeto completo.
  Product: {
    category: async (parent: Product, _args: unknown, context: GraphQLContext) =>
      context.catalog.getCategoryById(parent.categoryId),
    createdAt: (parent: Product) => iso(parent.createdAt),
    updatedAt: (parent: Product) => iso(parent.updatedAt),
  },

  Category: {
    products: async (parent: Category, _args: unknown, context: GraphQLContext) =>
      context.catalog.listProductsOfCategory(parent.id),
    createdAt: (parent: Category) => iso(parent.createdAt),
  },
};
