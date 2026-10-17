/**
 * productRepository.ts — Principios SRP, DIP y OCP
 *
 * Única responsabilidad: traducir entre el dominio (`Product`) y las filas de
 * la tabla `products`. Aquí vive todo el SQL del agregado producto y nada más:
 * ninguna regla de negocio, ninguna decisión de autorización.
 *
 * DIP: se declara primero la interfaz `IProductRepository`. La capa de
 * servicio depende de ella, no de esta clase, así que sustituir PostgreSQL por
 * un doble en memoria durante las pruebas no obliga a tocar el servicio.
 *
 * Todas las consultas usan parámetros posicionales (`$1`, `$2`, …). Nunca se
 * concatena un valor recibido del cliente dentro del SQL: es lo que cierra la
 * puerta a la inyección de SQL.
 */

import type { Pool, PoolClient } from 'pg';
import type {
  CreateProductInput,
  Page,
  Product,
  ProductFilter,
  UpdateProductInput,
} from '../types';

/** Fila cruda tal como la devuelve PostgreSQL. */
interface ProductRow {
  id: string;
  sku: string;
  name: string;
  description: string | null;
  price: number;
  currency: string;
  category_id: string | null;
  image_url: string | null;
  active: boolean;
  created_at: Date;
  updated_at: Date;
}

function toProduct(row: ProductRow): Product {
  return {
    id: row.id,
    sku: row.sku,
    name: row.name,
    description: row.description,
    price: row.price,
    currency: row.currency,
    categoryId: row.category_id,
    imageUrl: row.image_url,
    active: row.active,
    createdAt: row.created_at,
    updatedAt: row.updated_at,
  };
}

export interface IProductRepository {
  findById(id: string): Promise<Product | null>;
  findByIds(ids: string[]): Promise<Product[]>;
  findBySku(sku: string): Promise<Product | null>;
  search(filter: ProductFilter, limit: number, offset: number): Promise<Page<Product>>;
  create(input: CreateProductInput): Promise<Product>;
  update(id: string, input: UpdateProductInput): Promise<Product | null>;
  delete(id: string): Promise<boolean>;
}

export class PostgresProductRepository implements IProductRepository {
  constructor(private readonly db: Pool | PoolClient) {}

  async findById(id: string): Promise<Product | null> {
    const { rows } = await this.db.query<ProductRow>('SELECT * FROM products WHERE id = $1', [id]);
    return rows[0] ? toProduct(rows[0]) : null;
  }

  /**
   * Carga varios productos en una sola consulta.
   *
   * Existe por `order-service`: al hacer checkout necesita el precio y el
   * nombre de cada línea del carrito. Sin este método haría una consulta por
   * producto (el clásico problema N+1) y un carrito de diez artículos costaría
   * diez viajes de red entre servicios en lugar de uno.
   */
  async findByIds(ids: string[]): Promise<Product[]> {
    if (ids.length === 0) return [];
    const { rows } = await this.db.query<ProductRow>(
      'SELECT * FROM products WHERE id = ANY($1::uuid[])',
      [ids],
    );
    return rows.map(toProduct);
  }

  async findBySku(sku: string): Promise<Product | null> {
    const { rows } = await this.db.query<ProductRow>('SELECT * FROM products WHERE sku = $1', [sku]);
    return rows[0] ? toProduct(rows[0]) : null;
  }

  /**
   * Búsqueda paginada con filtros opcionales.
   *
   * Las condiciones se van acumulando en un arreglo y el índice del parámetro
   * se calcula sobre la marcha: así un filtro nuevo se agrega con tres líneas
   * y sin reescribir la consulta (OCP).
   */
  async search(filter: ProductFilter, limit: number, offset: number): Promise<Page<Product>> {
    const conditions: string[] = [];
    const params: unknown[] = [];

    if (filter.activeOnly !== false) {
      conditions.push('p.active = TRUE');
    }
    if (filter.search) {
      params.push(`%${filter.search}%`);
      conditions.push(`(p.name ILIKE $${params.length} OR p.sku ILIKE $${params.length})`);
    }
    if (filter.categorySlug) {
      params.push(filter.categorySlug);
      conditions.push(`c.slug = $${params.length}`);
    }
    if (filter.minPrice != null) {
      params.push(filter.minPrice);
      conditions.push(`p.price >= $${params.length}`);
    }
    if (filter.maxPrice != null) {
      params.push(filter.maxPrice);
      conditions.push(`p.price <= $${params.length}`);
    }

    const where = conditions.length > 0 ? `WHERE ${conditions.join(' AND ')}` : '';
    const from = 'FROM products p LEFT JOIN categories c ON c.id = p.category_id';

    const totalResult = await this.db.query<{ total: string }>(
      `SELECT COUNT(*)::text AS total ${from} ${where}`,
      params,
    );

    const { rows } = await this.db.query<ProductRow>(
      `SELECT p.* ${from} ${where} ORDER BY p.name ASC LIMIT $${params.length + 1} OFFSET $${params.length + 2}`,
      [...params, limit, offset],
    );

    return {
      items: rows.map(toProduct),
      total: Number.parseInt(totalResult.rows[0]?.total ?? '0', 10),
      limit,
      offset,
    };
  }

  async create(input: CreateProductInput): Promise<Product> {
    const { rows } = await this.db.query<ProductRow>(
      `INSERT INTO products (id, sku, name, description, price, currency, category_id, image_url)
       VALUES (gen_random_uuid(), $1, $2, $3, $4, COALESCE($5, 'GTQ'), $6, $7)
       RETURNING *`,
      [
        input.sku,
        input.name,
        input.description ?? null,
        input.price,
        input.currency ?? null,
        input.categoryId ?? null,
        input.imageUrl ?? null,
      ],
    );
    return toProduct(rows[0]!);
  }

  /**
   * Actualización parcial.
   *
   * `COALESCE($n, columna)` deja intacto el campo cuando el cliente no lo
   * envía. Es lo que permite que una mutación que solo cambia el precio no
   * borre la descripción por omisión.
   */
  async update(id: string, input: UpdateProductInput): Promise<Product | null> {
    const { rows } = await this.db.query<ProductRow>(
      `UPDATE products SET
         name        = COALESCE($2, name),
         description = COALESCE($3, description),
         price       = COALESCE($4, price),
         category_id = COALESCE($5, category_id),
         image_url   = COALESCE($6, image_url),
         active      = COALESCE($7, active),
         updated_at  = NOW()
       WHERE id = $1
       RETURNING *`,
      [
        id,
        input.name ?? null,
        input.description ?? null,
        input.price ?? null,
        input.categoryId ?? null,
        input.imageUrl ?? null,
        input.active ?? null,
      ],
    );
    return rows[0] ? toProduct(rows[0]) : null;
  }

  /**
   * Baja lógica, no borrado físico.
   *
   * Un producto puede estar referenciado por pedidos históricos que viven en
   * `order_db`. Borrar la fila dejaría esos pedidos apuntando al vacío, y como
   * las bases están separadas no hay clave foránea que lo impida. Marcarlo
   * inactivo lo saca de la vitrina y conserva la historia.
   */
  async delete(id: string): Promise<boolean> {
    const result = await this.db.query(
      'UPDATE products SET active = FALSE, updated_at = NOW() WHERE id = $1',
      [id],
    );
    return (result.rowCount ?? 0) > 0;
  }
}
