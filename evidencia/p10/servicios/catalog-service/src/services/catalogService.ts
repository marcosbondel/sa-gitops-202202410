/**
 * catalogService.ts — Principios SRP y DIP
 *
 * Única responsabilidad: las reglas de negocio del catálogo.
 *
 * DIP en acción: el constructor recibe `IProductRepository`,
 * `ICategoryRepository` y `AuditPublisher` como **abstracciones**. Este archivo
 * no importa `pg`, no sabe qué es una fila ni conoce GraphQL. Se puede probar
 * inyectando repositorios en memoria y un publicador nulo.
 */

import type { AuditPublisher } from '../clients/auditClient';
import { ConflictError, NotFoundError, ValidationError } from '../errors';
import type { ICategoryRepository } from '../repositories/categoryRepository';
import type { IProductRepository } from '../repositories/productRepository';
import type {
  Category,
  CreateProductInput,
  Page,
  Product,
  ProductFilter,
  UpdateProductInput,
} from '../types';

/** Tope de la paginación: sin él, `limit: 100000` volcaría la tabla entera. */
const MAX_PAGE_SIZE = 100;

export interface Actor {
  id: string | null;
  role: string | null;
  correlationId: string | null;
}

export class CatalogService {
  constructor(
    private readonly products: IProductRepository,
    private readonly categories: ICategoryRepository,
    private readonly audit: AuditPublisher,
  ) {}

  // ---------------------------------------------------------------- lectura

  async listProducts(
    filter: ProductFilter | null | undefined,
    limit: number,
    offset: number,
  ): Promise<Page<Product>> {
    const safeLimit = Math.min(Math.max(limit, 1), MAX_PAGE_SIZE);
    const safeOffset = Math.max(offset, 0);
    return this.products.search(filter ?? {}, safeLimit, safeOffset);
  }

  async getProduct(id: string): Promise<Product | null> {
    return this.products.findById(id);
  }

  /** Lote de productos por id. Lo consume `order-service` en el checkout. */
  async getProductsByIds(ids: string[]): Promise<Product[]> {
    return this.products.findByIds(ids);
  }

  async listCategories(): Promise<Category[]> {
    return this.categories.findAll();
  }

  async getCategoryById(id: string | null): Promise<Category | null> {
    return id ? this.categories.findById(id) : null;
  }

  async getCategoryBySlug(slug: string): Promise<Category | null> {
    return this.categories.findBySlug(slug);
  }

  async listProductsOfCategory(categoryId: string): Promise<Product[]> {
    const page = await this.products.search({ activeOnly: true }, MAX_PAGE_SIZE, 0);
    return page.items.filter((product) => product.categoryId === categoryId);
  }

  // -------------------------------------------------------------- escritura

  async createProduct(input: CreateProductInput, actor: Actor): Promise<Product> {
    if (input.price < 0) {
      throw new ValidationError('El precio no puede ser negativo');
    }
    if (await this.products.findBySku(input.sku)) {
      // Se comprueba antes para devolver un mensaje entendible; la restricción
      // UNIQUE de la tabla sigue siendo la garantía real ante dos peticiones
      // simultáneas con el mismo SKU.
      throw new ConflictError(`Ya existe un producto con el SKU ${input.sku}`);
    }
    if (input.categoryId && !(await this.categories.findById(input.categoryId))) {
      throw new NotFoundError(`La categoría ${input.categoryId} no existe`);
    }

    const product = await this.products.create(input);

    await this.audit.publish({
      action: 'product.created',
      actorId: actor.id,
      actorRole: actor.role,
      subjectType: 'product',
      subjectId: product.id,
      correlationId: actor.correlationId,
      data: { sku: product.sku, name: product.name, price: product.price },
    });

    return product;
  }

  async updateProduct(id: string, input: UpdateProductInput, actor: Actor): Promise<Product> {
    if (input.price != null && input.price < 0) {
      throw new ValidationError('El precio no puede ser negativo');
    }

    const product = await this.products.update(id, input);
    if (!product) {
      throw new NotFoundError(`No existe el producto ${id}`);
    }

    await this.audit.publish({
      action: 'product.updated',
      actorId: actor.id,
      actorRole: actor.role,
      subjectType: 'product',
      subjectId: product.id,
      correlationId: actor.correlationId,
      data: { changes: input },
    });

    return product;
  }

  async deleteProduct(id: string, actor: Actor): Promise<boolean> {
    const deleted = await this.products.delete(id);
    if (!deleted) {
      throw new NotFoundError(`No existe el producto ${id}`);
    }

    await this.audit.publish({
      action: 'product.deactivated',
      actorId: actor.id,
      actorRole: actor.role,
      subjectType: 'product',
      subjectId: id,
      correlationId: actor.correlationId,
    });

    return true;
  }

  async createCategory(
    name: string,
    slug: string,
    description: string | null,
    actor: Actor,
  ): Promise<Category> {
    if (await this.categories.findBySlug(slug)) {
      throw new ConflictError(`Ya existe una categoría con el slug ${slug}`);
    }

    const category = await this.categories.create(name, slug, description);

    await this.audit.publish({
      action: 'category.created',
      actorId: actor.id,
      actorRole: actor.role,
      subjectType: 'category',
      subjectId: category.id,
      correlationId: actor.correlationId,
      data: { name, slug },
    });

    return category;
  }
}
