/**
 * context.ts — Principios SRP y OCP
 *
 * Única responsabilidad: construir el contexto de cada petición GraphQL y
 * ofrecer las guardas de autorización.
 *
 * ## De dónde sale la identidad
 *
 * Este servicio **no valida JWT ni conoce la llave de firma**. El API Gateway
 * ya llamó a `auth-service /api/auth/introspect`, resolvió quién es el usuario
 * e inyectó el resultado en tres cabeceras:
 *
 *     X-User-Id        identificador del usuario autenticado
 *     X-User-Role      rol resuelto contra la base de usuarios
 *     X-Correlation-Id identificador de la petición para poder trazarla
 *
 * Esa es la razón por la que `catalog-service` no publica su puerto hacia
 * afuera en producción: si alguien pudiera llamarlo directamente, bastaría con
 * mandar `X-User-Role: Admin` a mano. La confianza en esas cabeceras se apoya
 * en que el único camino hasta este servicio pasa por el gateway (ver
 * docs/01-arquitectura.md §5).
 *
 * OCP: proteger una operación nueva se hace componiendo `requireAdmin(...)`
 * dentro del resolver; no hay que modificar estas funciones.
 */

import type { Request } from 'express';
import { GraphQLError } from 'graphql';
import type { CatalogService, Actor } from '../services/catalogService';

export const ROLE_ADMIN = 'Admin';

export interface GraphQLContext {
  actor: Actor;
  catalog: CatalogService;
}

function firstHeader(request: Request, name: string): string | null {
  const value = request.headers[name];
  if (Array.isArray(value)) return value[0] ?? null;
  return value ?? null;
}

export function buildContext(request: Request, catalog: CatalogService): GraphQLContext {
  return {
    actor: {
      id: firstHeader(request, 'x-user-id'),
      role: firstHeader(request, 'x-user-role'),
      correlationId: firstHeader(request, 'x-correlation-id'),
    },
    catalog,
  };
}

/**
 * Exige sesión iniciada. Devuelve el actor para no repetir el acceso.
 *
 * Las guardas lanzan `GraphQLError` y no los errores de dominio de `errors.ts`
 * porque esto ya es la capa de transporte: son la respuesta a "¿podés entrar?",
 * no a una regla del catálogo. Si lanzaran un error de dominio, Apollo no
 * sabría interpretarlo y lo reportaría como `INTERNAL_SERVER_ERROR`, con lo que
 * el cliente vería un fallo del servidor donde en realidad le faltaba permiso.
 */
export function requireAuth(context: GraphQLContext): Actor {
  if (!context.actor.id) {
    throw new GraphQLError('Se requiere iniciar sesión para esta operación', {
      extensions: { code: 'UNAUTHENTICATED' },
    });
  }
  return context.actor;
}

/**
 * Exige rol Admin.
 *
 * Se distingue 401 de 403 a propósito: al anónimo se le dice que inicie sesión
 * (`UNAUTHENTICATED`), y al Cliente autenticado que su rol no alcanza
 * (`FORBIDDEN`). Responder lo mismo a los dos obligaría al frontend a adivinar
 * si conviene mostrar la pantalla de login o un mensaje de permiso denegado.
 */
export function requireAdmin(context: GraphQLContext): Actor {
  const actor = requireAuth(context);
  if (actor.role !== ROLE_ADMIN) {
    throw new GraphQLError(
      `El rol '${actor.role}' no puede modificar el catálogo. Se requiere el rol ${ROLE_ADMIN}.`,
      { extensions: { code: 'FORBIDDEN' } },
    );
  }
  return actor;
}
