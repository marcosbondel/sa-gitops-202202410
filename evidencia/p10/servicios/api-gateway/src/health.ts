/**
 * health.ts — Principio SRP
 *
 * Única responsabilidad: reportar la salud del sistema completo.
 *
 * `GET /health` consulta en paralelo la sonda de los cuatro microservicios y
 * devuelve un cuadro con el estado de cada uno. Es la forma más rápida de
 * comprobar, con una sola petición, que el sistema entero está de pie —y es
 * también la demostración más directa de que el gateway realmente alcanza a
 * todos los servicios, algo que en el clúster no es obvio: si una
 * NetworkPolicy estuviera mal escrita, este endpoint lo delata de inmediato.
 *
 * Las consultas van en paralelo (`Promise.all`) y no en fila: con cuatro
 * servicios a 2 s de timeout cada uno, en serie el peor caso serían 8 s; en
 * paralelo son 2 s.
 *
 * Este endpoint NO es el que usa el kubelet. Las sondas de Kubernetes apuntan
 * a `/health/self`, `/health/ready` y `/health/startup`, que no consultan a
 * nadie. El motivo está explicado en `index.ts`.
 */

import { config } from './config';
import { routes, type RouteDefinition } from './routes';

export interface ServiceHealth {
  service: string;
  status: 'up' | 'down';
  language: string;
  api: string;
  prefix: string;
  latency_ms: number;
  detail?: string;
}

async function probe(route: RouteDefinition): Promise<ServiceHealth> {
  const startedAt = Date.now();
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), config.healthTimeoutMs);

  const base: Omit<ServiceHealth, 'status' | 'latency_ms'> = {
    service: route.name,
    language: route.language,
    api: route.api,
    prefix: route.prefix,
  };

  try {
    const response = await fetch(`${route.target}${route.healthPath}`, {
      signal: controller.signal,
    });
    return {
      ...base,
      status: response.ok ? 'up' : 'down',
      latency_ms: Date.now() - startedAt,
      ...(response.ok ? {} : { detail: `respondió ${response.status}` }),
    };
  } catch (error) {
    return {
      ...base,
      status: 'down',
      latency_ms: Date.now() - startedAt,
      detail: error instanceof Error ? error.message : String(error),
    };
  } finally {
    clearTimeout(timer);
  }
}

export async function collectSystemHealth(): Promise<{
  status: 'ok' | 'degraded';
  gateway: string;
  version: string;
  services: ServiceHealth[];
}> {
  const services = await Promise.all(routes.map(probe));

  return {
    // "degraded" y no "down": el gateway sigue atendiendo y el resto de
    // servicios sigue funcionando aunque uno esté caído. Es precisamente lo
    // que un monolito no puede decir.
    status: services.every((service) => service.status === 'up') ? 'ok' : 'degraded',
    gateway: config.serviceName,
    version: config.version,
    services,
  };
}
