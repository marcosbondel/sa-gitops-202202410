/**
 * errors.ts — Principio SRP
 *
 * Única responsabilidad: definir los errores de dominio del catálogo.
 *
 * La capa de servicio lanza estos errores, no `GraphQLError`. Así el servicio
 * se puede reutilizar desde un worker o una prueba sin arrastrar GraphQL, y
 * es el resolver —la capa de transporte— quien decide cómo se ve el error en
 * la respuesta. Es la misma separación que en los servicios de Python, donde
 * la capa de negocio nunca lanza `HTTPException`.
 */

export class DomainError extends Error {
  /** Código que el resolver copia a `extensions.code` de la respuesta GraphQL. */
  readonly code: string;

  constructor(message: string, code: string) {
    super(message);
    this.name = new.target.name;
    this.code = code;
  }
}

export class NotFoundError extends DomainError {
  constructor(message: string) {
    super(message, 'NOT_FOUND');
  }
}

export class ValidationError extends DomainError {
  constructor(message: string) {
    super(message, 'BAD_USER_INPUT');
  }
}

export class ConflictError extends DomainError {
  constructor(message: string) {
    super(message, 'CONFLICT');
  }
}

export class UnauthenticatedError extends DomainError {
  constructor(message = 'Se requiere iniciar sesión para esta operación') {
    super(message, 'UNAUTHENTICATED');
  }
}

export class ForbiddenError extends DomainError {
  constructor(message: string) {
    super(message, 'FORBIDDEN');
  }
}
