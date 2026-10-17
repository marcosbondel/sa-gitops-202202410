/**
 * pool.ts — Principio SRP
 *
 * Única responsabilidad: administrar el pool de conexiones a PostgreSQL.
 *
 * Se usa un pool y no una conexión por petición porque abrir una conexión a
 * PostgreSQL cuesta decenas de milisegundos: con 20 conexiones reutilizadas el
 * servicio atiende cientos de peticiones por segundo sin volver a negociar
 * nada con la base.
 */

import { Pool, types } from 'pg';
import { config } from '../config';
import { log } from '../telemetria/log';

// PostgreSQL devuelve NUMERIC como string para no perder precisión al pasar
// por el double de JavaScript. En un catálogo los precios caben de sobra en un
// number, así que se convierten aquí una sola vez en lugar de repartir
// `parseFloat` por todos los repositorios.
const PG_NUMERIC_OID = 1700;
types.setTypeParser(PG_NUMERIC_OID, (value: string) => Number.parseFloat(value));

export const pool = new Pool({
  connectionString: config.databaseUrl,
  max: 20,
  idleTimeoutMillis: 30_000,
  connectionTimeoutMillis: 5_000,
});

pool.on('error', (error) => {
  log.error('error inesperado en el pool de PostgreSQL', { 'error.message': error.message });
});

/**
 * Espera a que PostgreSQL acepte conexiones.
 *
 * En Kubernetes no existe `depends_on`. Los pods arrancan en paralelo y no hay
 * garantía de que PostgreSQL esté listo cuando este proceso se levante: el
 * StatefulSet puede estar todavía inicializando su volumen.
 *
 * Reintentar aquí es más barato que un initContainer que espere a la base,
 * porque además cubre el caso que el initContainer no cubre: que PostgreSQL se
 * reinicie con el servicio ya arriba.
 *
 * Este bucle es también la razón de que exista la **startup probe**. Sin ella,
 * la liveness empezaría a contar fallos durante estos hasta 30 segundos de
 * espera y mataría al pod justo mientras hacía lo correcto.
 */
export async function waitForDatabase(attempts = 15, delayMs = 2_000): Promise<void> {
  for (let attempt = 1; attempt <= attempts; attempt += 1) {
    try {
      await pool.query('SELECT 1');
      return;
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log.warn(`PostgreSQL no responde (intento ${attempt}/${attempts})`, { 'error.message': message });
      if (attempt === attempts) throw error;
      await new Promise((resolve) => setTimeout(resolve, delayMs));
    }
  }
}
