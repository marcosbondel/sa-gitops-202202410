/**
 * createProxy.ts — Principios SRP y OCP
 *
 * Única responsabilidad: construir el middleware que reenvía una petición a su
 * microservicio.
 *
 * Es una **fábrica**: recibe una `RouteDefinition` y devuelve el proxy ya
 * configurado. Los seis servicios se enrutan con la misma función; lo único
 * que cambia son los datos de la tabla de rutas.
 *
 * Nota importante sobre el cuerpo de la petición: el gateway **no** parsea
 * JSON. Si lo hiciera, consumiría el flujo de entrada y el proxy reenviaría un
 * cuerpo vacío, con lo que toda mutación GraphQL y todo POST se quedarían
 * colgados esperando datos que ya nadie va a mandar. Solo se leen las cookies,
 * que viajan en cabeceras y no tocan el cuerpo.
 */

import type { Request, Response } from 'express';
import { createProxyMiddleware, type RequestHandler } from 'http-proxy-middleware';
import type { RouteDefinition } from '../routes';
import { camposDeError, log } from '../telemetria/log';

/** Si el microservicio no responde en 30 s, se corta y se informa 504. */
const UPSTREAM_TIMEOUT_MS = 30_000;

export function createServiceProxy(route: RouteDefinition): RequestHandler {
  return createProxyMiddleware({
    target: route.target,
    changeOrigin: true,
    // Propaga IP de origen y protocolo en cabeceras X-Forwarded-*, para que
    // los servicios sepan quién llamó de verdad y no vean siempre al gateway.
    xfwd: true,
    proxyTimeout: UPSTREAM_TIMEOUT_MS,
    timeout: UPSTREAM_TIMEOUT_MS,

    /**
     * Express ya quitó el prefijo público al montar la ruta, así que aquí
     * llega la subruta. Se le antepone el prefijo con el que el servicio
     * publica sus endpoints internamente:
     *
     *   cliente  GET /api/orders/123
     *   express  →  /123
     *   upstream →  /api/orders/123
     *
     * Para los servicios GraphQL `upstreamPrefix` es vacío, de modo que
     * /api/catalog/graphql termina en /graphql.
     *
     * El caso de la barra sola merece explicación. Cuando la petición apunta
     * exactamente al prefijo (`POST /api/orders` o `GET /api/notifications?limit=3`),
     * Express deja `req.url` en `/` o en `/?limit=3`, y concatenarlo produciría
     * `/api/orders/`. FastAPI registra esa ruta sin barra final, así que
     * respondería `307 Temporary Redirect` hacia la versión sin barra —y ese
     * redirect apunta al nombre DNS interno `http://order-service:8000`, que
     * el navegador del cliente no puede resolver—. Normalizar aquí evita que
     * el checkout se rompa por un carácter.
     *
     * La ruta y la cadena de consulta se separan antes de normalizar: sin
     * eso, `/?limit=3` no se reconocería como "la raíz" y el problema
     * reaparecería en cuanto alguien filtrara un listado.
     */
    pathRewrite: (path: string) => {
      const queryIndex = path.indexOf('?');
      const pathname = queryIndex === -1 ? path : path.slice(0, queryIndex);
      const search = queryIndex === -1 ? '' : path.slice(queryIndex);
      const normalized = pathname === '/' ? '' : pathname;
      return `${route.upstreamPrefix}${normalized}${search}`;
    },

    on: {
      /**
       * Agrega al `Set-Cookie` de la respuesta la cookie de sesión renovada,
       * si la introspección devolvió un token nuevo.
       *
       * Se hace aquí y no con `res.cookie()` porque la respuesta la escribe el
       * proxy con las cabeceras del microservicio: hay que sumarse a ellas, no
       * competir. Se concatena en lugar de reemplazar para no borrar la cookie
       * que el propio servicio pudiera estar mandando (el logout, por ejemplo,
       * manda una que la borra).
       */
      proxyRes: (proxyRes, _req, res) => {
        const renewedCookie = (res as Response).locals?.renewedCookie as string | undefined;
        if (!renewedCookie) return;

        const existing = proxyRes.headers['set-cookie'] ?? [];
        proxyRes.headers['set-cookie'] = [
          ...(Array.isArray(existing) ? existing : [existing]),
          renewedCookie,
        ];
      },

      /**
       * El microservicio no contestó: está caído, reiniciándose o tardó
       * demasiado.
       *
       * El gateway responde 503 con el nombre del servicio afectado en lugar
       * de dejar caer la conexión. Es la diferencia entre "la tienda avisa que
       * el inventario no responde" y "el navegador se queda cargando".
       */
      error: (error, req, res) => {
        const path = (req as Request).originalUrl ?? '';
        log.error(`${route.name} no respondió`, {
          'upstream.service': route.name,
          'url.path': path,
          ...camposDeError(error),
        });

        const response = res as Response;
        if (typeof response.status !== 'function' || response.headersSent) return;

        response.status(503).json({
          error: 'SERVICE_UNAVAILABLE',
          service: route.name,
          detail: `El servicio ${route.name} no está disponible en este momento. Intente de nuevo en unos segundos.`,
        });
      },
    },
  });
}
