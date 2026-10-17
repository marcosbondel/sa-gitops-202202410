/**
 * iniciar.ts — Arranque de OpenTelemetry en el gateway (Práctica 10)
 *
 * Tiene que ser lo PRIMERO que se carga: `index.ts` lo importa en su primera
 * línea. Las instrumentaciones funcionan parcheando los módulos `http` y
 * `express` en el momento en que se cargan; si Express se importara antes que
 * este archivo, el gateway arrancaría sin un solo span y sin ningún error que
 * lo delatara.
 *
 * ## Las tres señales, y por qué cada una sale por un camino distinto
 *
 *   trazas    → OTLP/HTTP al Collector (`OTEL_EXPORTER_OTLP_ENDPOINT`), que
 *               las enriquece con los metadatos del pod y las manda a Tempo.
 *   métricas  → expuestas en :9464/metrics y RASPADAS por Prometheus.
 *   registros → JSON por la salida estándar; el Collector los lee del nodo.
 *
 * Las métricas no pasan por el Collector a propósito. Son las que gobiernan el
 * canary: Argo Rollouts decide si promueve o revierte consultando Prometheus.
 * Si viajaran por el Collector, una caída del Collector dejaría al canary sin
 * datos y bloquearía todas las entregas. Raspadas directamente, además, cada
 * serie llega con las etiquetas del pod —entre ellas
 * `rollouts-pod-template-hash`, la que distingue la versión candidata de la
 * estable— sin que el código de la aplicación tenga que saber que existe un
 * canary.
 *
 * ## Por qué no `@opentelemetry/sdk-node`
 *
 * Es el atajo habitual y trae de regalo exportadores gRPC, detectores de nube y
 * una docena de instrumentaciones que este servicio no usa. Aquí se arma con
 * las piezas justas: un proveedor de trazas, uno de métricas y tres
 * instrumentaciones (http, express, undici). Menos dependencias es menos
 * superficie para Trivy y una imagen más chica.
 *
 * ## El proveedor de métricas NO se registra como global
 *
 * Las instrumentaciones de http y undici emiten sus propias métricas
 * (`http.server.duration`, en milisegundos y con otros atributos) en cuanto
 * encuentran un MeterProvider global. Serían una segunda versión de la misma
 * medida, con nombres distintos en Node y en Python. Las métricas HTTP de esta
 * práctica las define `metricas.ts`, iguales en los tres servicios y con los
 * cortes del histograma alineados a los umbrales de los SLO.
 */

import { CompositePropagator, W3CBaggagePropagator, W3CTraceContextPropagator } from '@opentelemetry/core';
import { PrometheusExporter } from '@opentelemetry/exporter-prometheus';
import { OTLPTraceExporter } from '@opentelemetry/exporter-trace-otlp-http';
import { registerInstrumentations } from '@opentelemetry/instrumentation';
import { ExpressInstrumentation } from '@opentelemetry/instrumentation-express';
import { HttpInstrumentation } from '@opentelemetry/instrumentation-http';
import { UndiciInstrumentation } from '@opentelemetry/instrumentation-undici';
import { resourceFromAttributes } from '@opentelemetry/resources';
import { MeterProvider } from '@opentelemetry/sdk-metrics';
import { BatchSpanProcessor } from '@opentelemetry/sdk-trace-base';
import { NodeTracerProvider } from '@opentelemetry/sdk-trace-node';
import {
  ATTR_SERVICE_NAME,
  ATTR_SERVICE_VERSION,
} from '@opentelemetry/semantic-conventions';

export const NOMBRE_SERVICIO = process.env.OTEL_SERVICE_NAME ?? 'api-gateway';
const VERSION = process.env.APP_VERSION ?? 'desconocida';
const PUERTO_METRICAS = Number(process.env.METRICS_PORT ?? 9464);

const recurso = resourceFromAttributes({
  [ATTR_SERVICE_NAME]: NOMBRE_SERVICIO,
  [ATTR_SERVICE_VERSION]: VERSION,
  'deployment.environment.name': process.env.APP_ENV ?? 'development',
  // El nombre del pod lo pone el chart (`POD_NAME`, vía la API descendente).
  // El Collector añade además namespace, nodo y etiquetas del pod.
  'k8s.pod.name': process.env.POD_NAME ?? '',
});

// `OTEL_SDK_DISABLED=true` apaga la telemetría: para correr el gateway en una
// laptop sin Collector, o en una prueba unitaria, sin cambiar el código.
const desactivado = (process.env.OTEL_SDK_DISABLED ?? 'false') === 'true';

// ---------------------------------------------------------------------------
// Trazas
// ---------------------------------------------------------------------------
const proveedorTrazas = new NodeTracerProvider({
  resource: recurso,
  // Lote: los spans se acumulan y salen cada pocos segundos en una sola
  // petición. Exportar uno por uno pondría al Collector en el camino crítico
  // de cada petición del usuario.
  spanProcessors: desactivado ? [] : [new BatchSpanProcessor(new OTLPTraceExporter())],
});

// ## La propagación de contexto
//
// W3C Trace Context es lo que hace que una petición sea UNA traza y no tres:
// el gateway escribe la cabecera `traceparent` en cada llamada saliente
// (la instrumentación de http la inyecta en el proxy hacia order-service y
// catalog-service; la de undici, en el `fetch` de introspección contra
// auth-service), y el servicio de abajo la extrae y cuelga sus spans del span
// del gateway. Se declara explícitamente y no se deja al valor por defecto
// porque es un contrato entre servicios escritos en dos lenguajes: Python
// tiene que hablar exactamente el mismo formato.
proveedorTrazas.register({
  propagator: new CompositePropagator({
    propagators: [new W3CTraceContextPropagator(), new W3CBaggagePropagator()],
  }),
});

registerInstrumentations({
  tracerProvider: proveedorTrazas,
  instrumentations: [
    new HttpInstrumentation({
      // Las sondas de Kubernetes llegan cada pocos segundos a cada pod. No son
      // tráfico de usuarios: trazarlas llenaría Tempo de spans que nadie va a
      // mirar y diluiría las búsquedas.
      ignoreIncomingRequestHook: (request) => (request.url ?? '').startsWith('/health'),
    }),
    new ExpressInstrumentation(),
    new UndiciInstrumentation(),
  ],
});

// ---------------------------------------------------------------------------
// Métricas
// ---------------------------------------------------------------------------
const exportadorPrometheus = new PrometheusExporter({
  host: '0.0.0.0',
  port: PUERTO_METRICAS,
  preventServerStart: desactivado,
});

export const proveedorMetricas = new MeterProvider({
  resource: recurso,
  readers: [exportadorPrometheus],
});

export const medidor = proveedorMetricas.getMeter(NOMBRE_SERVICIO, VERSION);

export async function apagarTelemetria(): Promise<void> {
  // Vacía los spans pendientes: sin esto, las trazas de las últimas peticiones
  // antes de un `SIGTERM` —justo las de un rollout— se perderían.
  await Promise.allSettled([proveedorTrazas.shutdown(), proveedorMetricas.shutdown()]);
}
