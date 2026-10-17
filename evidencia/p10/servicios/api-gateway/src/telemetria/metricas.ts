/**
 * metricas.ts — Latencia, tráfico y errores de cada petición (Práctica 10)
 *
 * Un solo histograma, `http.server.request.duration`, con el mismo nombre, los
 * mismos atributos y los mismos cortes en los tres servicios instrumentados
 * (este gateway en Node y order-service y catalog-service). De él salen tres de
 * las cuatro señales de oro:
 *
 *   latencia   → los cubos del histograma        (histogram_quantile)
 *   tráfico    → la cuenta de observaciones      (rate de _count)
 *   errores    → la cuenta con estado 5xx        (rate de _count{...="5.."})
 *
 * En Prometheus aparece como `http_server_request_duration_seconds_bucket`,
 * `_count` y `_sum`, con las etiquetas `http_request_method`, `http_route` y
 * `http_response_status_code`.
 *
 * ## Los cortes del histograma NO son los de por defecto
 *
 * Un SLO de latencia del tipo «el 95 % de las peticiones en menos de 300 ms»
 * se calcula contando cuántas observaciones cayeron en el cubo `le="0.3"`. Si
 * ese cubo no existe, Prometheus interpola entre los vecinos y el indicador
 * pasa a ser una estimación. Por eso 0.3 —el umbral del SLO de catálogo— está
 * en la lista, y 0.5 y 1 —los umbrales del análisis del canary— también.
 *
 * ## La ruta, y por qué se normaliza
 *
 * `/api/orders/7f3c…/pay` y `/api/orders/a91e…/pay` son la misma operación. Si
 * cada identificador fuera un valor distinto de la etiqueta `http_route`, cada
 * pedido crearía series nuevas en Prometheus hasta agotarle la memoria. Los
 * segmentos que parecen identificadores se reemplazan por `{id}`, y lo que no
 * cae bajo ninguna ruta conocida se cuenta como `otra`.
 */

import type { NextFunction, Request, Response } from 'express';
import { trace } from '@opentelemetry/api';
import { routes } from '../routes';
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

const PREFIJOS = routes.map((route) => route.prefix);
const PARECE_ID = /^([0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}|\d+|[0-9a-f]{16,})$/i;
const SEGMENTO_LEGIBLE = /^[a-z][a-z-]{0,30}$/;

export function normalizarRuta(url: string): string {
  const camino = url.split('?')[0] ?? '';
  if (camino === '/' || camino === '') return '/';
  const prefijo = PREFIJOS.find((p) => camino === p || camino.startsWith(`${p}/`));
  if (!prefijo) return 'otra';
  const resto = camino
    .slice(prefijo.length)
    .split('/')
    .filter(Boolean)
    .slice(0, 3)
    .map((segmento) =>
      PARECE_ID.test(segmento) || !SEGMENTO_LEGIBLE.test(segmento) ? '{id}' : segmento,
    );
  return [prefijo, ...resto].join('/');
}

/**
 * Mide cada petición y deja una línea de acceso en el registro.
 *
 * Va al principio de la cadena de Express, justo después de la correlación,
 * para que la duración incluya todo lo que hace el gateway —autenticación,
 * límite de peticiones, proxy— y no solo la espera al servicio de abajo.
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
      correlation_id: response.locals.correlationId ?? null,
    };
    if (estado >= 500) log.error('petición fallida', campos, span);
    else log.info('petición atendida', campos, span);
  });

  next();
}
