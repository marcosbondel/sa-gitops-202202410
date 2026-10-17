/**
 * metricas.ts — Latencia, tráfico y errores de cada petición (Práctica 10)
 *
 * Copia de `api-gateway/src/telemetria/metricas.ts`: el mismo histograma, con
 * el mismo nombre, atributos y cortes en los tres servicios instrumentados. De
 * él salen tres de las cuatro señales de oro:
 *
 *   latencia   → los cubos del histograma        (histogram_quantile)
 *   tráfico    → la cuenta de observaciones      (rate de _count)
 *   errores    → la cuenta con estado 5xx        (rate de _count{...="5.."})
 *
 * En Prometheus aparece como `http_server_request_duration_seconds_bucket`,
 * `_count` y `_sum`, con las etiquetas `http_request_method`, `http_route` y
 * `http_response_status_code`.
 *
 * Los cortes y su razón están explicados en la copia del gateway. Aquí solo
 * hay dos rutas: `/graphql` y `/`; todo lo demás es `otra`.
 */

import type { NextFunction, Request, Response } from 'express';
import { trace } from '@opentelemetry/api';
import { medidor } from './iniciar';
import { log } from './log';

export const CORTES_SEGUNDOS = [
  0.005, 0.01, 0.025, 0.05, 0.1, 0.2, 0.3, 0.5, 0.75, 1, 2.5, 5, 10,
];

// El nombre lleva `_seconds` escrito a mano: el exportador de Prometheus de
// Python añade el sufijo de la unidad (`unit: 's'` → `_seconds`) y el de
// JavaScript no. Sin esto, la misma medida se llamaría distinto según el
// lenguaje del servicio y cada consulta tendría que nombrar las dos series.
const duracion = medidor.createHistogram('http.server.request.duration_seconds', {
  description: 'Duración de las peticiones HTTP atendidas, desde que llegan hasta que se responden.',
  unit: 's',
  advice: { explicitBucketBoundaries: CORTES_SEGUNDOS },
});

export function normalizarRuta(url: string): string {
  const camino = url.split('?')[0] ?? '';
  if (camino === '/' || camino === '') return '/';
  if (camino === '/graphql') return '/graphql';
  return 'otra';
}

/**
 * Mide cada petición y deja una línea de acceso en el registro.
 *
 * Va al principio de la cadena de Express, antes de CORS y de Apollo.
 *
 * Las sondas de salud no se miden: no son usuarios, y en un servicio con poco
 * tráfico las sondas de Kubernetes serían la mayoría de las observaciones y
 * maquillarían la latencia.
 */
export function medirPeticiones(request: Request, response: Response, next: NextFunction): void {
  if (request.path.startsWith('/health')) {
    next();
    return;
  }

  const inicio = process.hrtime.bigint();
  // El span se captura AQUÍ, en el contexto de la petición, y no dentro del
  // evento `finish`: ese evento puede dispararse fuera del contexto activo y
  // la línea de acceso quedaría sin `trace_id`.
  const span = trace.getActiveSpan();

  response.on('finish', () => {
    const segundos = Number(process.hrtime.bigint() - inicio) / 1e9;
    const ruta = normalizarRuta(request.originalUrl);
    const estado = response.statusCode;

    duracion.record(segundos, {
      'http.request.method': request.method,
      'http.route': ruta,
      'http.response.status_code': estado,
    });

    const campos = {
      'http.request.method': request.method,
      'http.route': ruta,
      'url.path': request.originalUrl.split('?')[0],
      'http.response.status_code': estado,
      duration_ms: Math.round(segundos * 1000 * 10) / 10,
      correlation_id: request.headers['x-correlation-id'] ?? null,
    };
    if (estado >= 500) log.error('petición fallida', campos, span);
    else log.info('petición atendida', campos, span);
  });

  next();
}
