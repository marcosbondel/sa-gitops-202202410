/**
 * authClient.ts — Principios SRP y DIP
 *
 * Única responsabilidad: preguntarle a `auth-service` quién está detrás de un
 * token, y cachear la respuesta durante unos segundos.
 *
 * **Aquí es donde el módulo de autenticación de la Práctica 2 se integra con
 * el resto del sistema.** El gateway no valida el JWT por su cuenta —no
 * conoce la llave de firma y no debe conocerla—: le pregunta al servicio que
 * la emitió. La consecuencia práctica es que revocar un usuario, cambiarle el
 * rol o borrarlo surte efecto sin redesplegar ni reconfigurar nada, porque la
 * respuesta se resuelve contra la base de usuarios y no contra el contenido
 * del token.
 */

import { config } from '../config';

export interface IntrospectedUser {
  id: number;
  full_name: string;
  email: string;
  role: string;
}

export interface IntrospectionResult {
  active: boolean;
  reason?: string | null;
  user?: IntrospectedUser | null;
  /** JWT nuevo cuando el original venció dentro de la ventana de gracia. */
  renewed_token?: string | null;
}

/** Se distingue "el token no vale" de "no pude preguntar". */
export class AuthServiceUnavailableError extends Error {
  constructor(cause: string) {
    super(`auth-service no está disponible: ${cause}`);
  }
}

interface CacheEntry {
  result: IntrospectionResult;
  expiresAt: number;
}

export interface TokenIntrospector {
  introspect(token: string): Promise<IntrospectionResult>;
}

export class AuthServiceIntrospector implements TokenIntrospector {
  /**
   * Caché en memoria del proceso.
   *
   * Es deliberadamente local y no compartida: con varias réplicas del gateway
   * cada una mantiene la suya, lo que a lo sumo produce alguna consulta
   * repetida a auth-service. Meter Redis para compartirla agregaría un
   * componente con estado al borde del sistema para ahorrar una consulta de
   * milisegundos; no vale el intercambio a esta escala.
   */
  private readonly cache = new Map<string, CacheEntry>();

  constructor(private readonly baseUrl: string) {}

  async introspect(token: string): Promise<IntrospectionResult> {
    const cached = this.cache.get(token);
    if (cached && cached.expiresAt > Date.now()) {
      return cached.result;
    }

    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), config.introspectionTimeoutMs);

    let response: Response;
    try {
      response = await fetch(`${this.baseUrl}/api/auth/introspect`, {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          // El token viaja en una cabecera propia y no como cookie: así
          // auth-service no depende de que el gateway le reenvíe la cookie
          // completa del navegador.
          'X-Session-Token': token,
        },
        signal: controller.signal,
      });
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      throw new AuthServiceUnavailableError(message);
    } finally {
      clearTimeout(timer);
    }

    if (!response.ok) {
      throw new AuthServiceUnavailableError(`respondió ${response.status}`);
    }

    const result = (await response.json()) as IntrospectionResult;

    // Un resultado con token renovado NO se cachea: si se guardara, las
    // siguientes peticiones reutilizarían el mismo token nuevo y volverían a
    // pedir la renovación una y otra vez.
    if (!result.renewed_token) {
      this.cache.set(token, {
        result,
        expiresAt: Date.now() + config.introspectionCacheMs,
      });
      this.pruneCache();
    }

    return result;
  }

  /**
   * Descarta entradas vencidas.
   *
   * Sin esto, cada token que alguna vez pasó por el gateway se quedaría en el
   * Map para siempre: una fuga de memoria lenta pero segura en un proceso que
   * corre durante semanas.
   */
  private pruneCache(): void {
    if (this.cache.size < 1_000) return;
    const now = Date.now();
    for (const [token, entry] of this.cache) {
      if (entry.expiresAt <= now) this.cache.delete(token);
    }
  }
}

export const introspector: TokenIntrospector = new AuthServiceIntrospector(config.authServiceUrl);
