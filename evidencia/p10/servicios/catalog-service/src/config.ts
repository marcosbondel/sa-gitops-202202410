/**
 * config.ts — Principio SRP (Single Responsibility Principle)
 *
 * Única responsabilidad: leer y validar la configuración del proceso.
 * Ningún otro módulo toca `process.env`; todos importan `config` desde aquí.
 * Eso permite saber de un vistazo qué necesita el servicio para arrancar y
 * hace que un error de configuración falle al inicio y no a media petición.
 *
 * ## Por qué las credenciales llegan troceadas
 *
 * Host, puerto y nombre de base vienen del **ConfigMap**; usuario y contraseña,
 * del **Secret**. La cadena de conexión se arma aquí, en memoria.
 *
 * Mandar la URL completa ya formada sería más simple, pero esa URL contiene la
 * contraseña: en el ConfigMap queda a la vista de cualquiera con permiso de
 * lectura sobre el namespace; en el Secret obliga a duplicar allí el host y el
 * nombre de la base, que no son secretos. Trocear pone cada dato donde
 * corresponde.
 *
 * ## `required` no es decorativo
 *
 * Un servicio que arranca sin contraseña de base y falla en la primera consulta
 * es peor que uno que no arranca: Kubernetes lo marca `Running`, el Service le
 * manda tráfico y los errores aparecen del lado del cliente. Fallar aquí hace
 * que el pod entre en CrashLoopBackOff, que es ruidoso y honesto.
 */

function required(name: string, fallback?: string): string {
  const value = process.env[name] ?? fallback;
  if (value === undefined || value === '') {
    throw new Error(`Falta la variable de entorno obligatoria ${name}`);
  }
  return value;
}

const postgresHost = process.env.POSTGRES_HOST ?? 'sa-platform-postgresql';
const postgresPort = Number(process.env.POSTGRES_PORT ?? 5432);
const postgresDb = process.env.POSTGRES_DB ?? 'catalog_db';
const postgresUser = process.env.POSTGRES_USER ?? 'catalog_user';
// Sin valor por defecto a propósito: es lo único que no puede inventarse.
const postgresPassword = required('POSTGRES_PASSWORD');

export const config = {
  serviceName: 'catalog-service',
  language: 'Node.js 20 / TypeScript / Apollo Server',
  api: 'GraphQL',
  version: process.env.APP_VERSION ?? '2.0.0',
  env: process.env.NODE_ENV ?? 'development',
  port: Number(process.env.PORT ?? 4000),

  /**
   * `catalog_db` es privada de este servicio. Vive en el mismo StatefulSet de
   * PostgreSQL que las demás, pero con su propio usuario: las credenciales de
   * este servicio no sirven para leer `auth_db` ni `order_db`.
   */
  databaseUrl:
    `postgres://${postgresUser}:${encodeURIComponent(postgresPassword)}` +
    `@${postgresHost}:${postgresPort}/${postgresDb}`,

  /** Partes sueltas, para poder reportarlas sin exponer la contraseña. */
  postgresHost,
  postgresPort,
  postgresDb,
} as const;
