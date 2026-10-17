/**
 * categoryRepository.ts — Principios SRP y DIP
 *
 * Única responsabilidad: leer y escribir categorías.
 *
 * Es un archivo aparte del repositorio de productos aunque comparta tabla
 * vecina: son dos agregados distintos y cada uno cambia por su cuenta. Un
 * único "CatalogRepository" con todo adentro crecería hasta volverse el lugar
 * donde nadie quiere entrar.
 */

import type { Pool, PoolClient } from 'pg';
import type { Category } from '../types';

interface CategoryRow {
  id: string;
  name: string;
  slug: string;
  description: string | null;
  created_at: Date;
}

function toCategory(row: CategoryRow): Category {
  return {
    id: row.id,
    name: row.name,
    slug: row.slug,
    description: row.description,
    createdAt: row.created_at,
  };
}

export interface ICategoryRepository {
  findAll(): Promise<Category[]>;
  findById(id: string): Promise<Category | null>;
  findBySlug(slug: string): Promise<Category | null>;
  create(name: string, slug: string, description: string | null): Promise<Category>;
}

export class PostgresCategoryRepository implements ICategoryRepository {
  constructor(private readonly db: Pool | PoolClient) {}

  async findAll(): Promise<Category[]> {
    const { rows } = await this.db.query<CategoryRow>('SELECT * FROM categories ORDER BY name ASC');
    return rows.map(toCategory);
  }

  async findById(id: string): Promise<Category | null> {
    const { rows } = await this.db.query<CategoryRow>('SELECT * FROM categories WHERE id = $1', [id]);
    return rows[0] ? toCategory(rows[0]) : null;
  }

  async findBySlug(slug: string): Promise<Category | null> {
    const { rows } = await this.db.query<CategoryRow>('SELECT * FROM categories WHERE slug = $1', [
      slug,
    ]);
    return rows[0] ? toCategory(rows[0]) : null;
  }

  async create(name: string, slug: string, description: string | null): Promise<Category> {
    const { rows } = await this.db.query<CategoryRow>(
      `INSERT INTO categories (id, name, slug, description)
       VALUES (gen_random_uuid(), $1, $2, $3)
       RETURNING *`,
      [name, slug, description],
    );
    return toCategory(rows[0]!);
  }
}
