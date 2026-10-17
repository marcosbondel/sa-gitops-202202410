/**
 * index.ts — Punto de entrada de catalog-service.
 *
 * Responsabilidad: arrancar el proceso. Es el *composition root* del servicio:
 * el único lugar donde se decide qué implementación concreta recibe cada
 * abstracción (qué repositorio, qué publicador de auditoría). Cambiar
 * PostgreSQL por otro motor, o apagar la auditoría, se hace aquí en una línea
 * y sin tocar el servicio ni los resolvers.
 *
 * Se monta Apollo sobre Express en lugar de usar el servidor autónomo porque
 * el servicio necesita convivir con sondas REST: el kubelet consulta la salud
 * con un GET simple, y obligarlo a mandar una consulta GraphQL para eso sería
 * incómodo —y en el caso de la liveness, imposible de configurar—.
 */

// Práctica 10: OpenTelemetry tiene que cargarse ANTES que express, graphql y
// pg para poder instrumentarlos. Ver `telemetria/iniciar.ts`.
import { apagarTelemetria } from './telemetria/iniciar';

import { SpanStatusCode, trace } from '@opentelemetry/api';
import { ApolloServer, type ApolloServerPlugin } from '@apollo/server';
import { expressMiddleware } from '@apollo/server/express4';
import { ApolloServerPluginDrainHttpServer } from '@apollo/server/plugin/drainHttpServer';
import bodyParser from 'body-parser';
import cors from 'cors';
import express from 'express';
import http from 'node:http';

import { auditPublisher } from './clients/auditClient';
import { config } from './config';
import { migrateAndSeed } from './db/migrate';
import { pool, waitForDatabase } from './db/pool';
import { buildContext, type GraphQLContext } from './graphql/context';
import { resolvers } from './graphql/resolvers';
import { typeDefs } from './graphql/typeDefs';
import { camposDeError, log } from './telemetria/log';
import { medirPeticiones } from './telemetria/metricas';

/**
 * Práctica 10 — los errores de GraphQL, visibles.
 *
 * Apollo responde los errores de los resolvers con HTTP 200 y un arreglo
 * `errors` en el cuerpo: para las métricas HTTP, una consulta que falló es
 * indistinguible de una que funcionó. Este plugin deja cada error en el
 * registro y en el span de la petición, con el mismo `trace_id`, para que el
 * recorrido desde una alerta de order-service termine aquí, en la causa.
 */
const registrarErroresGraphQL: ApolloServerPlugin<GraphQLContext> = {
  async requestDidStart() {
    return {
      async didEncounterErrors({ errors, operationName }) {
        const span = trace.getActiveSpan();
        for (const error of errors) {
          span?.recordException(error);
          log.error('error en la operación GraphQL', {
            'graphql.operation.name': operationName ?? null,
            ...camposDeError(error.originalError ?? error),
          });
        }
        span?.setStatus({ code: SpanStatusCode.ERROR, message: 'la operación GraphQL devolvió errores' });
      },
    };
  },
};
import { PostgresCategoryRepository } from './repositories/categoryRepository';
import { PostgresProductRepository } from './repositories/productRepository';
import { CatalogService } from './services/catalogService';

async function main(): Promise<void> {
  await waitForDatabase();
  await migrateAndSeed();

  // --- Composition root: aquí se inyectan las dependencias concretas -------
  const catalogService = new CatalogService(
    new PostgresProductRepository(pool),
    new PostgresCategoryRepository(pool),
    auditPublisher,
  );

  const app = express();
  const httpServer = http.createServer(app);

  const apollo = new ApolloServer<GraphQLContext>({
    typeDefs,
    resolvers,
    // La introspección queda activa para que el evaluador pueda explorar el
    // esquema desde el Apollo Sandbox. En una tienda real se apagaría en
    // producción para no publicar el mapa completo de la API.
    introspection: true,
    // Nunca se devuelve el rastro de pila al cliente. Apollo lo incluye por
    // defecto fuera de producción, y describe la estructura interna del
    // servicio —rutas de archivos, nombres de funciones— a cualquiera que
    // provoque un error a propósito.
    includeStacktraceInErrorResponses: false,
    plugins: [ApolloServerPluginDrainHttpServer({ httpServer }), registrarErroresGraphQL],
  });

  await apollo.start();

  app.use(medirPeticiones);
  app.use(cors({ origin: true, credentials: true }));

  // --- Las tres sondas de Kubernetes --------------------------------------
  //
  // Son tres endpoints porque Kubernetes hace tres preguntas distintas:
  //
  //   /health         → liveness.  "¿Sigue vivo el proceso?"  NO toca la base.
  //   /health/ready   → readiness. "¿Le mando tráfico?"       SÍ la toca.
  //   /health/startup → startup.   "¿Ya terminó de arrancar?"
  //
  // Que la liveness no consulte PostgreSQL es deliberado: si lo hiciera, una
  // caída de la base reiniciaría en bucle todos los pods de todos los
  // servicios, y reiniciar un proceso sano nunca arregló una base caída. La
  // readiness sí la consulta, porque un catálogo sin base no puede responder
  // nada útil; fallar ahí saca al pod del Service sin matarlo y vuelve solo.
  //
  // La startup cubre el arranque, que en este servicio es el más lento del
  // sistema: `waitForDatabase` reintenta hasta 30 segundos y `migrateAndSeed`
  // crea las tablas y siembra el catálogo. Como Apollo se monta después de
  // todo eso, mientras el proceso no escuche este endpoint ni siquiera
  // responde, que es justo lo que la startup probe necesita observar.

  app.get('/health', (_req, res) => {
    res.json({
      status: 'ok',
      service: config.serviceName,
      language: config.language,
      api: config.api,
      version: config.version,
      env: config.env,
    });
  });

  app.get('/health/startup', (_req, res) => {
    res.json({ status: 'ok', service: config.serviceName });
  });

  app.get('/health/ready', async (_req, res) => {
    // `SELECT 1` es la comprobación más barata que realmente prueba algo:
    // toma una conexión del pool y va y vuelve del servidor. Verificar solo
    // que el pool existe no distinguiría una base caída de una sana.
    try {
      await pool.query('SELECT 1');
      res.json({ status: 'ready', service: config.serviceName });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      log.warn('readiness en fallo: la base de datos no responde', { 'error.message': message });
      res.status(503).json({
        status: 'not-ready',
        service: config.serviceName,
        dependency: 'postgresql',
      });
    }
  });

  app.use(
    '/graphql',
    bodyParser.json({ limit: '1mb' }),
    expressMiddleware(apollo, {
      context: async ({ req }) => buildContext(req, catalogService),
    }),
  );

  await new Promise<void>((resolve) => {
    httpServer.listen({ port: config.port, host: '0.0.0.0' }, resolve);
  });

  log.info(`GraphQL escuchando en http://0.0.0.0:${config.port}/graphql`, { version: config.version });

  // Apagado ordenado. Kubernetes manda SIGTERM y espera
  // `terminationGracePeriodSeconds` antes de SIGKILL. Cerrar el servidor y el
  // pool en ese margen evita dejar conexiones colgadas en PostgreSQL cada vez
  // que el HPA reduce réplicas o el RollingUpdate reemplaza un pod —y con
  // `maxUnavailable: 0` eso ocurre en cada `helm upgrade`.
  const shutdown = async (signal: string): Promise<void> => {
    log.info(`${signal} recibido, cerrando…`);
    await apollo.stop();
    await pool.end();
    await apagarTelemetria();
    process.exit(0);
  };
  process.on('SIGTERM', () => void shutdown('SIGTERM'));
  process.on('SIGINT', () => void shutdown('SIGINT'));
}

main().catch((error) => {
  log.error('fallo al arrancar', camposDeError(error));
  process.exit(1);
});
