/**
 * authenticate.ts — Principios SRP, OCP y DIP
 *
 * Única responsabilidad: resolver la identidad del solicitante y decidir si la
 * petición sigue su camino.
 *
 * Es el middleware más importante del gateway. Hace cuatro cosas, en este
 * orden, y cada una tiene un motivo:
 *
 * 1. **Limpia las cabeceras de identidad que venga trayendo el cliente.**
 *    Los microservicios confían en `X-User-Id` y `X-User-Role`. Si un cliente
 *    pudiera mandarlas y el gateway las dejara pasar, cualquiera se declararía
 *    Admin con un encabezado. Esta línea es la que hace que el modelo de
 *    confianza se sostenga, y por eso va antes que todo lo demás.
 *
 * 2. **Extrae el JWT de la cookie HTTP-only** que instaló auth-service en la
 *    Práctica 2. El token nunca es legible por JavaScript en el navegador, así
 *    que el cliente no puede mandarlo por otra vía aunque quisiera.
 *
 * 3. **Pregunta a auth-service quién es** (introspección) en lugar de validar
 *    la firma por su cuenta. El gateway no conoce la llave del JWT: solo
 *    auth-service la tiene, y así el día que rote no hay que redesplegar el
 *    borde.
 *
 * 4. **Inyecta la identidad resuelta** hacia el microservicio de destino.
 *
 * DIP: depende de la abstracción `TokenIntrospector`, no del cliente HTTP
 * concreto. OCP: el comportamiento cambia según el modo declarado en la tabla
 * de rutas, no reescribiendo este archivo.
 */

import type { NextFunction, Request, Response } from 'express';
import {
  AuthServiceUnavailableError,
  type IntrospectionResult,
  type TokenIntrospector,
} from '../clients/authClient';
import { config } from '../config';
import { camposDeError, log } from '../telemetria/log';
import type { AuthMode } from '../routes';

export const ROLE_ADMIN = 'Admin';

/** Cabeceras de identidad: las escribe el gateway y nadie más. */
const IDENTITY_HEADERS = ['x-user-id', 'x-user-role', 'x-user-email'] as const;

function stripSpoofedIdentityHeaders(request: Request): void {
  for (const header of IDENTITY_HEADERS) {
    delete request.headers[header];
  }
}

function injectIdentity(request: Request, result: IntrospectionResult): void {
  if (!result.user) return;
  request.headers['x-user-id'] = String(result.user.id);
  request.headers['x-user-role'] = result.user.role;
  request.headers['x-user-email'] = result.user.email;
}

/**
 * Serializa la cookie renovada.
 *
 * Se arma a mano porque no basta con `res.cookie()`: la respuesta la escribe
 * el proxy con las cabeceras que vienen del microservicio, así que esta cadena
 * se guarda en `res.locals` y el proxy la agrega al `Set-Cookie` de salida
 * (ver proxy/createProxy.ts).
 */
function serializeSessionCookie(token: string, maxAgeSeconds: number): string {
  const parts = [
    `${config.cookieName}=${token}`,
    'Path=/',
    'HttpOnly',
    `SameSite=${config.cookieSameSite.charAt(0).toUpperCase()}${config.cookieSameSite.slice(1)}`,
    `Max-Age=${maxAgeSeconds}`,
  ];
  if (config.cookieSecure) parts.push('Secure');
  return parts.join('; ');
}

/** Vigencia de la cookie renovada: una hora, holgada sobre la del token. */
const RENEWED_COOKIE_MAX_AGE_SECONDS = 3_600;

export function createAuthenticator(introspector: TokenIntrospector) {
  return function authenticate(mode: AuthMode) {
    return async (request: Request, response: Response, next: NextFunction): Promise<void> => {
      stripSpoofedIdentityHeaders(request);

      if (mode === 'public') {
        next();
        return;
      }

      const token = request.cookies?.[config.cookieName] as string | undefined;

      if (!token) {
        if (mode === 'optional') {
          // Visitante anónimo: pasa sin identidad. El microservicio decidirá
          // qué le muestra.
          next();
          return;
        }
        response.status(401).json({
          error: 'UNAUTHENTICATED',
          detail: 'No hay sesión activa. Inicie sesión para continuar.',
        });
        return;
      }

      let result: IntrospectionResult;
      try {
        result = await introspector.introspect(token);
      } catch (error) {
        if (error instanceof AuthServiceUnavailableError) {
          // **Fail-closed.** Si el servicio de permisos no responde, se
          // rechaza. La alternativa —dejar pasar mientras auth está caído—
          // convierte una caída en una escalada de privilegios.
          log.error('introspección fallida: auth-service no respondió', camposDeError(error));
          response.status(503).json({
            error: 'AUTH_UNAVAILABLE',
            detail:
              'El servicio de autenticación no está disponible. ' +
              'Por seguridad la petición no se procesó.',
          });
          return;
        }
        next(error);
        return;
      }

      if (!result.active) {
        if (mode === 'optional') {
          next();
          return;
        }
        response.status(401).json({
          error: 'UNAUTHENTICATED',
          detail: result.reason ?? 'La sesión no es válida.',
        });
        return;
      }

      // Renovación automática heredada de la Práctica 2: el token venció pero
      // seguía dentro de la ventana de gracia, así que auth-service emitió uno
      // nuevo y aquí se prepara la cookie que lo reemplaza. El usuario no
      // percibe ninguna interrupción.
      if (result.renewed_token) {
        response.locals.renewedCookie = serializeSessionCookie(
          result.renewed_token,
          RENEWED_COOKIE_MAX_AGE_SECONDS,
        );
        response.setHeader('X-Token-Renewed', 'true');
      }

      if (mode === 'admin' && result.user?.role !== ROLE_ADMIN) {
        // 403 y no 401: el usuario está bien autenticado, lo que le falta es
        // permiso. Confundirlos haría que el frontend mandara a iniciar sesión
        // a alguien que ya la tiene.
        response.status(403).json({
          error: 'FORBIDDEN',
          detail: `El rol '${result.user?.role}' no tiene acceso a este recurso. Se requiere ${ROLE_ADMIN}.`,
        });
        return;
      }

      injectIdentity(request, result);
      response.locals.user = result.user;
      next();
    };
  };
}
