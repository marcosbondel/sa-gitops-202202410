/**
 * config.ts — Principio SRP
 *
 * Única responsabilidad: leer la configuración del gateway.
 *
 * ## Qué cambió al pasar de Docker Compose a Kubernetes
 *
 * En la Práctica 4 las direcciones eran nombres DNS de Docker
 * (`http://order-service:8000`). En Kubernetes siguen siendo nombres DNS, pero
 * de un `Service`: `http://sa-platform-order-service:8000`. La forma del
 * archivo no cambia —y ese es justamente el punto—: el gateway nunca supo
 * dónde estaban los servicios, solo leyó variables de entorno. Cambiar de
 * orquestador fue cambiar el ConfigMap que las llena, no el código.
 *
 * Ninguna de estas variables tiene un valor sensible: todas provienen del
 * ConfigMap que genera el chart. Las credenciales viven en Secrets y este
 * servicio no necesita ninguna, porque no habla con la base de datos.
 */

export const config = {
  serviceName: 'api-gateway',
  version: process.env.APP_VERSION ?? '2.0.0',
  env: process.env.NODE_ENV ?? 'development',
  port: Number(process.env.PORT ?? 8080),

  // --- Ubicación de los microservicios ---
  authServiceUrl: process.env.AUTH_SERVICE_URL ?? 'http://auth-service:8000',
  catalogServiceUrl: process.env.CATALOG_SERVICE_URL ?? 'http://catalog-service:4000',
  orderServiceUrl: process.env.ORDER_SERVICE_URL ?? 'http://order-service:8000',
  notificationServiceUrl:
    process.env.NOTIFICATION_SERVICE_URL ?? 'http://notification-service:8000',

  // --- Cookie de sesión ---
  // El gateway necesita conocer el nombre de la cookie para extraer el token,
  // y sus banderas para poder reescribirla cuando auth-service la renueva.
  cookieName: process.env.COOKIE_NAME ?? 'access_token',
  cookieSecure: (process.env.COOKIE_SECURE ?? 'false') === 'true',
  cookieSameSite: (process.env.COOKIE_SAMESITE ?? 'lax') as 'lax' | 'strict' | 'none',

  // --- CORS ---
  // Con cookies no se puede usar "*": la especificación prohíbe combinar
  // `Access-Control-Allow-Credentials: true` con un origen comodín.
  corsOrigins: (process.env.CORS_ORIGINS ?? 'http://sa-p5.local,http://localhost:8080')
    .split(',')
    .map((origin) => origin.trim())
    .filter(Boolean),

  // --- Límite de peticiones por IP ---
  //
  // En Kubernetes este límite se vuelve delicado y conviene decir por qué. El
  // gateway corre replicado (2 a 5 pods por el HPA) y `express-rate-limit`
  // cuenta en la memoria de cada proceso: con 3 réplicas, el límite efectivo
  // es tres veces el configurado. Un contador compartido exigiría Redis, que
  // esta práctica declara fuera de alcance.
  //
  // La consecuencia práctica importa para la prueba de carga: si el límite
  // fuera bajo, k6 recibiría 429 y el HPA nunca vería CPU. Por eso el chart lo
  // sube en `values-dev.yaml` y lo baja en `values-prod.yaml`.
  rateLimitWindowMs: Number(process.env.RATE_LIMIT_WINDOW_MS ?? 60_000),
  rateLimitMax: Number(process.env.RATE_LIMIT_MAX ?? 300),

  /**
   * Cuánto se cachea el resultado de la introspección de un token.
   *
   * Es el equilibrio clásico: sin caché, cada petición de cada usuario golpea
   * a auth-service y su base; con una caché larga, revocar un usuario tardaría
   * en surtir efecto. Treinta segundos quitan de encima más del 99 % del
   * tráfico de introspección y acotan la ventana de revocación a medio minuto.
   */
  introspectionCacheMs: Number(process.env.INTROSPECTION_CACHE_MS ?? 30_000),

  /** Si auth-service no responde en este plazo, se rechaza la petición. */
  introspectionTimeoutMs: Number(process.env.INTROSPECTION_TIMEOUT_MS ?? 3_000),

  /** Timeout de la sonda de salud agregada. */
  healthTimeoutMs: Number(process.env.HEALTH_TIMEOUT_MS ?? 2_000),
} as const;
