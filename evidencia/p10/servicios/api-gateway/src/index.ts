/**
 * index.ts — Punto de entrada del API Gateway.
 *
 * ## La cadena de middlewares
 *
 * El orden no es decorativo: cada eslabón depende de que el anterior ya haya
 * corrido, y el primero que rechaza corta la cadena, de modo que una petición
 * sin sesión nunca llega a consumir recursos de ningún microservicio.
 *
 *   1. CORS             — resuelve el preflight antes de gastar nada más.
 *   2. Correlación      — todo lo que venga después ya puede citar el id.
 *   2b. Medición        — (Práctica 10) duración, estado y línea de acceso de
 *                         cada petición; ver `telemetria/metricas.ts`.
 *   3. Rate limiting    — frena el abuso antes de que llegue a auth-service.
 *   4. cookie-parser    — deja la cookie disponible para el paso siguiente.
 *   5. Autenticación    — introspección contra auth-service e inyección de
 *                         identidad, según el modo declarado por la ruta.
 *   6. Filtro de método — cierra los endpoints internos.
 *   7. Proxy            — reenvía al microservicio.
 *   8. 404 y errores    — lo que no encajó en nada.
 *
 * El paso 3 va antes del 5 a propósito: limitar primero significa que una
 * ráfaga de peticiones con tokens basura se detiene en el borde en lugar de
 * convertirse en una ráfaga de consultas a la base de usuarios.
 */

// Práctica 10: OpenTelemetry tiene que cargarse ANTES que express y http para
// poder instrumentarlos. Ver `telemetria/iniciar.ts`.
import { apagarTelemetria } from './telemetria/iniciar';

import cookieParser from 'cookie-parser';
import cors from 'cors';
import express from 'express';
import rateLimit from 'express-rate-limit';

import { introspector } from './clients/authClient';
import { config } from './config';
import { collectSystemHealth } from './health';
import { createAuthenticator } from './middleware/authenticate';
import { correlation } from './middleware/correlation';
import { errorHandler, notFoundHandler } from './middleware/errorHandler';
import { createServiceProxy } from './proxy/createProxy';
import { routes } from './routes';
import { log } from './telemetria/log';
import { medirPeticiones } from './telemetria/metricas';

const app = express();
const authenticate = createAuthenticator(introspector);

// El gateway está detrás del Ingress Controller. Sin esto, express-rate-limit
// vería siempre la IP del controlador en lugar de la del cliente y limitaría a
// todo el mundo junto: un solo usuario abusivo bloquearía a los demás.
// El valor 1 es el número de proxies de confianza que hay delante (ingress-nginx).
app.set('trust proxy', 1);

// --- 1 · CORS ---------------------------------------------------------------
app.use(
  cors({
    origin: config.corsOrigins,
    // Indispensable para que el navegador acepte y reenvíe la cookie de
    // sesión. La especificación prohíbe combinarlo con un origen comodín, por
    // eso los orígenes se enumeran en CORS_ORIGINS.
    credentials: true,
    exposedHeaders: ['X-Correlation-Id', 'X-Token-Renewed'],
  }),
);

// --- 2 · Identificador de correlación --------------------------------------
app.use(correlation);
app.use(medirPeticiones);

// --- 3 · Límite de peticiones por IP ---------------------------------------
app.use(
  rateLimit({
    windowMs: config.rateLimitWindowMs,
    limit: config.rateLimitMax,
    standardHeaders: 'draft-7',
    legacyHeaders: false,
    message: {
      error: 'RATE_LIMITED',
      detail: 'Demasiadas peticiones. Espere un momento antes de volver a intentar.',
    },
    // La salud no cuenta para el límite: el monitoreo la consulta cada pocos
    // segundos y no tiene sentido que se autobloquee.
    skip: (request) => request.path.startsWith('/health'),
  }),
);

// --- 4 · Lectura de cookies -------------------------------------------------
// Solo cookies. El cuerpo NO se parsea: hacerlo dejaría el flujo consumido y
// el proxy reenviaría peticiones vacías (ver proxy/createProxy.ts).
app.use(cookieParser());

// --- Endpoints propios del gateway -----------------------------------------

/** Salud agregada de todo el sistema. */
app.get('/health', async (_request, response) => {
  const health = await collectSystemHealth();
  response.status(health.status === 'ok' ? 200 : 503).json(health);
});

/**
 * Salud del gateway solo, sin consultar a nadie.
 *
 * ## Por qué son tres sondas y no una
 *
 * Kubernetes hace tres preguntas distintas y este servicio las responde en
 * tres endpoints distintos, porque confundirlas tiene consecuencias caras:
 *
 *   · `/health/self`  → **liveness**. "¿Sigue vivo el proceso?" Deliberadamente
 *     NO consulta a los microservicios. Si lo hiciera, una caída de
 *     order-service reiniciaría al gateway —matando también el tráfico del
 *     catálogo, que estaba perfectamente— y convertiría una falla parcial en
 *     una caída total. Es el error más común con liveness probes.
 *
 *   · `/health/ready` → **readiness**. "¿Le mando tráfico?" El gateway está
 *     listo en cuanto puede aceptar conexiones: su trabajo es enrutar, y ya
 *     sabe responder 503 por servicio cuando un destino no contesta. Sacarlo
 *     del balanceador porque un upstream está caído dejaría a los clientes sin
 *     siquiera ese mensaje de error.
 *
 *   · `/health/startup` → **startup**. "¿Ya terminó de arrancar?" Node levanta
 *     en menos de un segundo, así que la respuesta es la misma; la sonda
 *     existe para que Kubernetes espere con paciencia el arranque sin que la
 *     liveness empiece a contar fallos mientras tanto.
 *
 * El agregado real —quién está arriba y quién no— vive en `GET /health`, que
 * es para operadores y no para el kubelet.
 */
const selfCheck = (_request: express.Request, response: express.Response): void => {
  response.json({
    status: 'ok',
    service: config.serviceName,
    version: config.version,
    env: config.env,
  });
};

app.get('/health/self', selfCheck);
app.get('/health/ready', selfCheck);
app.get('/health/startup', selfCheck);

/** Mapa de la API: qué hay detrás de cada prefijo y qué exige cada uno. */
app.get('/', (_request, response) => {
  response.json({
    gateway: config.serviceName,
    version: config.version,
    description:
      'Punto único de entrada de la tienda en línea. Enruta hacia cuatro ' +
      'microservicios escritos en dos lenguajes, con REST y GraphQL. En el ' +
      'clúster es el único servicio alcanzable desde afuera: entra por el ' +
      'Ingress y las NetworkPolicies bloquean cualquier otra ruta.',
    routes: routes.map((route) => ({
      prefix: route.prefix,
      service: route.name,
      language: route.language,
      api: route.api,
      auth: route.auth,
      description: route.description,
    })),
    health: '/health',
  });
});

// --- 5, 6 y 7 · Autenticación, filtro y proxy, ruta por ruta ----------------
//
// Se recorre la tabla de rutas. Agregar un microservicio no toca este archivo:
// basta con declararlo en routes.ts (OCP).
for (const route of routes) {
  const middlewares: express.RequestHandler[] = [authenticate(route.auth)];

  if (route.isAllowed) {
    middlewares.push((request, response, next) => {
      // `request.url` ya viene sin el prefijo público porque Express lo quitó
      // al montar la ruta; es exactamente la subruta que evalúa la regla.
      const subPath = request.url.split('?')[0] ?? '';
      if (route.isAllowed!(request.method, subPath)) {
        next();
        return;
      }
      response.status(404).json({
        error: 'NOT_FOUND',
        detail:
          `${request.method} ${route.prefix}${subPath} no se expone a través del gateway. ` +
          'Es un endpoint de uso interno entre microservicios.',
      });
    });
  }

  middlewares.push(createServiceProxy(route));

  app.use(route.prefix, ...middlewares);
}

// --- 8 · Lo que no encajó ---------------------------------------------------
app.use(notFoundHandler);
app.use(errorHandler);

const server = app.listen(config.port, '0.0.0.0', () => {
  log.info(`escuchando en http://0.0.0.0:${config.port}`, {
    version: config.version,
    routes: routes.map((route) => `${route.prefix} → ${route.name} [${route.api}] auth=${route.auth}`),
  });
});

const shutdown = (signal: string): void => {
  log.info(`${signal} recibido, cerrando…`);
  server.close(() => {
    void apagarTelemetria().finally(() => process.exit(0));
  });
};
process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
