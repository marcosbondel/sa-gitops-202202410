/**
 * log.ts — Registros estructurados (Práctica 10)
 *
 * Una línea de JSON por evento, por la salida estándar. El Collector de
 * OpenTelemetry la lee del disco del nodo, la interpreta y la manda a Loki.
 *
 * ## Los dos campos que hacen que un registro sirva para algo
 *
 * `trace_id` y `span_id` se toman del span activo en el momento de escribir. Es
 * el puente entre las señales: desde una traza en Tempo se llega a sus
 * registros buscando ese `trace_id` en Loki, y desde un registro de error se
 * salta a la traza completa con un clic. Sin estos dos campos, los registros de
 * los tres servicios serían tres montones separados que alguien tendría que
 * cruzar a ojo por la hora.
 *
 * Fuera de una petición (el arranque, el apagado) no hay span: el campo va en
 * `null` y no se omite. Que todas las líneas tengan la misma forma es lo que
 * permite consultarlas por campo sin casos especiales.
 *
 * ## Por qué no pino o winston
 *
 * Serían una dependencia más para escribir un `JSON.stringify`. El gateway
 * escribe pocas líneas —el acceso de cada petición y los errores— y no
 * necesita rotación, transportes ni niveles configurables en caliente.
 */

import { isSpanContextValid, trace, type Span } from '@opentelemetry/api';
import { NOMBRE_SERVICIO } from './iniciar';

export type Nivel = 'debug' | 'info' | 'warn' | 'error';

export function registrar(
  nivel: Nivel,
  mensaje: string,
  campos: Record<string, unknown> = {},
  span: Span | undefined = trace.getActiveSpan(),
): void {
  const contexto = span?.spanContext();
  const valido = contexto !== undefined && isSpanContextValid(contexto);

  const linea = {
    timestamp: new Date().toISOString(),
    level: nivel,
    service: NOMBRE_SERVICIO,
    message: mensaje,
    trace_id: valido ? contexto.traceId : null,
    span_id: valido ? contexto.spanId : null,
    ...campos,
  };
  process.stdout.write(`${JSON.stringify(linea)}\n`);
}

export const log = {
  info: (mensaje: string, campos?: Record<string, unknown>, span?: Span) =>
    registrar('info', mensaje, campos, span ?? trace.getActiveSpan()),
  warn: (mensaje: string, campos?: Record<string, unknown>, span?: Span) =>
    registrar('warn', mensaje, campos, span ?? trace.getActiveSpan()),
  error: (mensaje: string, campos?: Record<string, unknown>, span?: Span) =>
    registrar('error', mensaje, campos, span ?? trace.getActiveSpan()),
};

/** Un error como campos de registro: tipo, mensaje y pila. */
export function camposDeError(error: unknown): Record<string, unknown> {
  if (error instanceof Error) {
    return { 'error.type': error.name, 'error.message': error.message, 'error.stack': error.stack };
  }
  return { 'error.type': typeof error, 'error.message': String(error) };
}
