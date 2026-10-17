/**
 * types.ts — Principio SRP
 *
 * Única responsabilidad: describir el modelo de dominio del catálogo.
 *
 * Estos tipos son el idioma común de repositorios, servicios y resolvers.
 * Nótese que no llevan decoradores ni heredan de ninguna clase de la base de
 * datos: son datos planos, y por eso el día que se cambie `pg` por otro
 * cliente no hay que tocarlos.
 */

export interface Category {
  id: string;
  name: string;
  slug: string;
  description: string | null;
  createdAt: Date;
}

export interface Product {
  id: string;
  sku: string;
  name: string;
  description: string | null;
  price: number;
  currency: string;
  categoryId: string | null;
  imageUrl: string | null;
  active: boolean;
  createdAt: Date;
  updatedAt: Date;
}

export interface ProductFilter {
  search?: string | null;
  categorySlug?: string | null;
  minPrice?: number | null;
  maxPrice?: number | null;
  /** Por defecto true: la vitrina no muestra productos dados de baja. */
  activeOnly?: boolean | null;
}

export interface Page<T> {
  items: T[];
  total: number;
  limit: number;
  offset: number;
}

export interface CreateProductInput {
  sku: string;
  name: string;
  description?: string | null;
  price: number;
  currency?: string | null;
  categoryId?: string | null;
  imageUrl?: string | null;
}

export interface UpdateProductInput {
  name?: string | null;
  description?: string | null;
  price?: number | null;
  categoryId?: string | null;
  imageUrl?: string | null;
  active?: boolean | null;
}
