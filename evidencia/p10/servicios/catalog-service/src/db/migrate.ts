/**
 * migrate.ts — Principio SRP
 *
 * Única responsabilidad: dejar el esquema de `catalog_db` listo y sembrar el
 * catálogo de demostración.
 *
 * Todo es idempotente (`IF NOT EXISTS`, `ON CONFLICT DO NOTHING`), así que se
 * ejecuta en cada arranque sin duplicar nada.
 *
 * **Los identificadores de la semilla son fijos, no aleatorios.** Es una
 * decisión deliberada: `inventory-service` siembra las existencias de estos
 * mismos productos en su propia base, y como cada servicio tiene su base
 * separada no hay clave foránea que los una. Compartir UUID constantes es lo
 * que permite que ambos hablen del mismo producto sin acoplarse por base de
 * datos. En producción esa correspondencia la crearía un evento
 * `product.created`, no una constante.
 */

import { pool } from './pool';
import { log } from '../telemetria/log';

const SCHEMA = `
  CREATE TABLE IF NOT EXISTS categories (
    id          UUID PRIMARY KEY,
    name        VARCHAR(120) NOT NULL,
    slug        VARCHAR(120) NOT NULL UNIQUE,
    description TEXT,
    created_at  TIMESTAMPTZ NOT NULL DEFAULT NOW()
  );

  CREATE TABLE IF NOT EXISTS products (
    id          UUID PRIMARY KEY,
    sku         VARCHAR(40)  NOT NULL UNIQUE,
    name        VARCHAR(200) NOT NULL,
    description TEXT,
    price       NUMERIC(12,2) NOT NULL CHECK (price >= 0),
    currency    CHAR(3)      NOT NULL DEFAULT 'GTQ',
    category_id UUID         REFERENCES categories(id) ON DELETE SET NULL,
    image_url   TEXT,
    active      BOOLEAN      NOT NULL DEFAULT TRUE,
    created_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW(),
    updated_at  TIMESTAMPTZ  NOT NULL DEFAULT NOW()
  );

  -- El listado siempre filtra por categoría y por estado activo.
  CREATE INDEX IF NOT EXISTS idx_products_category ON products (category_id);
  CREATE INDEX IF NOT EXISTS idx_products_active   ON products (active);
`;

const SEED_CATEGORIES = `
  INSERT INTO categories (id, name, slug, description) VALUES
    ('22222222-2222-4222-8222-000000000001', 'Cómputo',    'computo',    'Laptops, monitores y equipo de escritorio'),
    ('22222222-2222-4222-8222-000000000002', 'Accesorios', 'accesorios', 'Teclados, ratones y periféricos'),
    ('22222222-2222-4222-8222-000000000003', 'Audio',      'audio',      'Audífonos y bocinas'),
    ('22222222-2222-4222-8222-000000000004', 'Telefonía',  'telefonia',  'Teléfonos inteligentes y accesorios'),
    ('22222222-2222-4222-8222-000000000005', 'Mobiliario', 'mobiliario', 'Sillas y escritorios de oficina')
  ON CONFLICT (id) DO NOTHING;
`;

const SEED_PRODUCTS = `
  INSERT INTO products (id, sku, name, description, price, currency, category_id) VALUES
    ('11111111-1111-4111-8111-000000000001', 'LAP-001', 'Laptop Pro 14"',                   'Procesador de 12 núcleos, 32 GB de RAM y 1 TB de almacenamiento', 12999.00, 'GTQ', '22222222-2222-4222-8222-000000000001'),
    ('11111111-1111-4111-8111-000000000002', 'LAP-002', 'Laptop Air 13"',                   'Ultraligera, 16 GB de RAM y 14 horas de batería',                  8499.00, 'GTQ', '22222222-2222-4222-8222-000000000001'),
    ('11111111-1111-4111-8111-000000000003', 'MON-001', 'Monitor 27" 4K',                   'Panel IPS, 144 Hz y entrada USB-C con carga',                      3299.00, 'GTQ', '22222222-2222-4222-8222-000000000001'),
    ('11111111-1111-4111-8111-000000000004', 'TEC-001', 'Teclado mecánico RGB',             'Switches lineales, distribución en español',                        749.00, 'GTQ', '22222222-2222-4222-8222-000000000002'),
    ('11111111-1111-4111-8111-000000000005', 'MOU-001', 'Mouse inalámbrico ergonómico',     'Sensor de 8000 DPI y batería de 70 días',                            329.00, 'GTQ', '22222222-2222-4222-8222-000000000002'),
    ('11111111-1111-4111-8111-000000000006', 'AUD-001', 'Audífonos con cancelación de ruido','Cancelación activa y 30 horas de reproducción',                     1899.00, 'GTQ', '22222222-2222-4222-8222-000000000003'),
    ('11111111-1111-4111-8111-000000000007', 'AUD-002', 'Bocina Bluetooth portátil',        'Resistente al agua IPX7 y 12 horas de autonomía',                    599.00, 'GTQ', '22222222-2222-4222-8222-000000000003'),
    ('11111111-1111-4111-8111-000000000008', 'CEL-001', 'Teléfono Nova 5G',                 'Pantalla AMOLED de 6.7", 256 GB y cámara de 108 MP',                5499.00, 'GTQ', '22222222-2222-4222-8222-000000000004'),
    ('11111111-1111-4111-8111-000000000009', 'CEL-002', 'Teléfono Nova Lite',               'Pantalla de 6.1", 128 GB y batería de 5000 mAh',                    2199.00, 'GTQ', '22222222-2222-4222-8222-000000000004'),
    ('11111111-1111-4111-8111-000000000010', 'SIL-001', 'Silla ergonómica de oficina',      'Soporte lumbar ajustable y descansabrazos 4D',                      2599.00, 'GTQ', '22222222-2222-4222-8222-000000000005')
  ON CONFLICT (id) DO NOTHING;
`;

export async function migrateAndSeed(): Promise<void> {
  await pool.query(SCHEMA);
  await pool.query(SEED_CATEGORIES);
  await pool.query(SEED_PRODUCTS);

  const { rows } = await pool.query<{ count: string }>('SELECT COUNT(*)::text AS count FROM products');
  log.info('esquema listo', { productos: Number(rows[0]?.count ?? 0) });
}
