/**
 * correlation.ts — Principio SRP
 *
 * Única responsabilidad: garantizar que toda petición lleve un identificador
 * de correlación, y devolvérselo al cliente.
 *
 * ## Por qué es lo primero que hace el gateway
 *
 * Una sola compra toca cuatro procesos: el gateway pregunta a auth, order
 * consulta catalog y publica un evento, y el consumidor de notification lo
 * procesa después. Sin un hilo común, investigar "¿qué pasó con el pedido de
 * las 10:42?" obliga a cruzar a mano cuatro registros con relojes distintos.
 *
 * El `X-Correlation-Id` es ese hilo: se genera aquí, viaja en las cabeceras a
 * cada servicio y —esto es lo que cambió en esta práctica— **también viaja
 * dentro del mensaje que se publica en el broker**.
 *
 * Ese detalle deja de ser cosmético cuando la comunicación se vuelve
 * asíncrona. En una cadena de llamadas HTTP el contexto se propaga solo,
 * porque cada servicio llama al siguiente en la misma pila. Con un broker de
 * por medio la pila se rompe: el consumidor despierta minutos después, en otro
 * pod, sin nada del request original. Si el identificador no viaja en el
 * cuerpo del mensaje, la traza se corta justo en el salto asíncrono, que es
 * precisamente donde uno más necesita seguirla.
 *
 * Si el cliente ya trae uno, se respeta en lugar de generar otro: así una
 * traza que empezó en el navegador o en otro sistema no se corta al entrar.
 */

import { randomUUID } from 'node:crypto';
import type { NextFunction, Request, Response } from 'express';

export const CORRELATION_HEADER = 'x-correlation-id';

export function correlation(request: Request, response: Response, next: NextFunction): void {
  const incoming = request.headers[CORRELATION_HEADER];
  const correlationId =
    (Array.isArray(incoming) ? incoming[0] : incoming)?.trim() || randomUUID();

  // Hacia adentro: los microservicios lo reciben en la petición proxificada.
  request.headers[CORRELATION_HEADER] = correlationId;
  // Hacia afuera: el cliente puede citarlo al reportar un problema.
  response.setHeader('X-Correlation-Id', correlationId);
  response.locals.correlationId = correlationId;

  next();
}
