/**
 * routes.ts — Principios SRP y OCP
 *
 * Única responsabilidad: declarar **qué** enruta el gateway y con qué reglas.
 *
 * Esta tabla es el corazón del gateway y está escrita como datos, no como
 * código: agregar o quitar un microservicio es agregar o quitar un objeto de
 * este arreglo. Ni `index.ts` ni los middlewares cambian. Eso es OCP en su
 * forma más literal: abierto a la extensión, cerrado a la modificación.
 *
 * Esa propiedad se puso a prueba al pasar de la Práctica 4 a esta: el alcance
 * bajó de seis microservicios a cuatro, y el único archivo que hubo que tocar
 * fue este. Es la clase de cambio que en un gateway con un `if` por servicio
 * habría tocado media docena de archivos.
 *
 * ## Los cuatro modos de autenticación
 *
 *   public   — no se mira el token. Login y registro entran aquí, porque
 *              exigir sesión para iniciar sesión sería un círculo.
 *   optional — si hay token válido se resuelve la identidad y se propaga; si
 *              no, la petición pasa igual como anónima. Es lo que permite que
 *              cualquiera navegue la vitrina y que, al mismo tiempo, un Admin
 *              autenticado pueda crear productos por el mismo endpoint.
 *   required — sin sesión válida, 401 y no se toca al microservicio.
 *   admin    — además del 401, 403 si el rol no es Admin.
 *
 * ## Endpoints que deliberadamente NO se exponen
 *
 * `POST /api/auth/introspect` existe para que el gateway resuelva identidades,
 * no para el público. Si el gateway lo enrutara, cualquiera podría sondear
 * tokens ajenos. `isAllowed` lo bloquea en el borde.
 *
 * Esta tabla es la primera de las **dos** capas de aislamiento del sistema. La
 * segunda son las NetworkPolicies del chart: aunque alguien se saltara esta
 * regla, el tráfico que no venga del gateway ni siquiera llega a los pods.
 * Una es control de acceso a nivel de aplicación (qué se puede pedir); la otra
 * es control a nivel de red (quién puede siquiera conectarse).
 */

import { config } from './config';

export type AuthMode = 'public' | 'optional' | 'required' | 'admin';

export interface RouteDefinition {
  /** Nombre del microservicio de destino. */
  name: string;
  /** Prefijo público, tal como lo ve el cliente. */
  prefix: string;
  /** Dirección interna del servicio (DNS del Service de Kubernetes). */
  target: string;
  /** Prefijo con el que el servicio publica sus rutas internamente. */
  upstreamPrefix: string;
  auth: AuthMode;
  /** Ruta de la sonda de salud dentro del servicio. */
  healthPath: string;
  language: string;
  api: 'REST' | 'GraphQL';
  description: string;
  /**
   * Filtro fino por método y subruta. Devuelve false para cerrar la puerta
   * antes de que la petición salga del gateway.
   */
  isAllowed?: (method: string, subPath: string) => boolean;
}

export const routes: RouteDefinition[] = [
  {
    name: 'auth-service',
    prefix: '/api/auth',
    target: config.authServiceUrl,
    upstreamPrefix: '/api/auth',
    auth: 'public',
    healthPath: '/health',
    language: 'Python 3.12 / FastAPI',
    api: 'REST',
    description: 'Registro, inicio de sesión, sesión actual y cierre de sesión.',
    // La introspección es una conversación entre el gateway y auth-service.
    // Exponerla dejaría que cualquiera comprobara tokens ajenos desde afuera.
    isAllowed: (_method, subPath) => !subPath.startsWith('/introspect'),
  },
  {
    name: 'catalog-service',
    prefix: '/api/catalog',
    target: config.catalogServiceUrl,
    upstreamPrefix: '',
    auth: 'optional',
    healthPath: '/health',
    language: 'Node.js 20 / TypeScript / Apollo',
    api: 'GraphQL',
    description:
      'Catálogo de productos y categorías. Las consultas son públicas; ' +
      'las mutaciones exigen rol Admin y las valida el propio servicio.',
  },
  {
    name: 'order-service',
    prefix: '/api/orders',
    target: config.orderServiceUrl,
    upstreamPrefix: '/api/orders',
    auth: 'required',
    healthPath: '/health',
    language: 'Python 3.12 / FastAPI',
    api: 'REST',
    description:
      'Carrito, checkout, pago y cancelación. Publica los eventos del pedido ' +
      'en el broker en lugar de esperar a que se notifique al cliente.',
  },
  {
    name: 'notification-service',
    prefix: '/api/notifications',
    target: config.notificationServiceUrl,
    upstreamPrefix: '/api/notifications',
    auth: 'required',
    healthPath: '/health',
    language: 'Python 3.12 / FastAPI',
    api: 'REST',
    description:
      'Bandeja de notificaciones del usuario y resúmenes operativos. La API ' +
      'es de solo lectura: quien escribe aquí es el consumidor del broker.',
    // Crear notificaciones dejó de ser una llamada HTTP: ahora se publica un
    // evento. Exponer un POST aquí sería dejar abierta la puerta trasera que
    // el flujo asíncrono acaba de cerrar.
    isAllowed: (method) => method === 'GET',
  },
];
