/**
 * errorHandler.ts — Principio SRP
 *
 * Única responsabilidad: dar una respuesta coherente a lo que no encaja en
 * ninguna ruta y a lo que falla sin haber sido previsto.
 */

import type { NextFunction, Request, Response } from 'express';
import { SpanStatusCode, trace } from '@opentelemetry/api';
import { routes } from '../routes';
import { camposDeError, log } from '../telemetria/log';

/**
 * Ruta desconocida.
 *
 * Se listan los prefijos válidos en la respuesta: el gateway es la puerta del
 * sistema y quien se equivoca de dirección merece saber cuáles existen.
 */
export function notFoundHandler(request: Request, response: Response): void {
  response.status(404).json({
    error: 'NOT_FOUND',
    detail: `El gateway no tiene ninguna ruta para ${request.method} ${request.path}.`,
    available_prefixes: routes.map((route) => route.prefix),
  });
}

export function errorHandler(
  error: unknown,
  _request: Request,
  response: Response,
  // Express reconoce al manejador de errores por su aridad de 4 argumentos.
  _next: NextFunction,
): void {
  // Práctica 10: el error queda en el span (Tempo lo marca en rojo y guarda
  // la excepción como evento) y en el registro, con el mismo `trace_id`. Es el
  // final del recorrido de la alerta a la causa: aquí está la pila.
  const span = trace.getActiveSpan();
  if (span) {
    span.recordException(error instanceof Error ? error : new Error(String(error)));
    span.setStatus({ code: SpanStatusCode.ERROR, message: 'error no controlado en el gateway' });
  }
  log.error('error no controlado', camposDeError(error), span);

  if (response.headersSent) return;

  // Nunca se devuelve el mensaje original ni el rastro de pila: describirían
  // la estructura interna del sistema a quien esté probando dónde falla.
  response.status(500).json({
    error: 'INTERNAL_ERROR',
    detail: 'Ocurrió un error interno en el gateway.',
    correlation_id: response.locals.correlationId ?? null,
  });
}
