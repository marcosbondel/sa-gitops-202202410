/**
 * auditClient.ts — Principios SRP y DIP
 *
 * Única responsabilidad: definir el puerto por el que catalog-service deja
 * constancia de lo que ocurre, y su implementación actual.
 *
 * ## Por qué la implementación es "no hacer nada"
 *
 * En la Práctica 4 aquí vivía un cliente HTTP contra `audit-service`. La
 * Práctica 5 limita el alcance a cuatro microservicios más el gateway, y
 * audit-service quedó fuera.
 *
 * El puerto se conserva porque describe una necesidad real del dominio —dejar
 * constancia de quién cambió qué en el catálogo— y porque `CatalogService`
 * depende de esta abstracción, no de HTTP (DIP). Cuando la bitácora vuelva,
 * será una implementación nueva y una línea distinta en el composition root de
 * `index.ts`; ni el servicio ni los resolvers se enteran.
 *
 * La alternativa —borrar el parámetro de `CatalogService`— habría convertido
 * el regreso de la bitácora en una modificación de la capa de negocio. Es
 * exactamente el acoplamiento que la abstracción existe para evitar.
 *
 * Hay además un motivo operativo inmediato: dejar el cliente HTTP apuntando a
 * un servicio inexistente costaría un timeout en cada mutación del catálogo, y
 * las NetworkPolicies del chart bloquearían esa salida de todos modos.
 */

export interface AuditEvent {
  action: string;
  actorId?: string | null;
  actorRole?: string | null;
  subjectType?: string | null;
  subjectId?: string | null;
  correlationId?: string | null;
  data?: Record<string, unknown>;
}

export interface AuditPublisher {
  /** Registra un hecho ocurrido en el servicio. Nunca lanza. */
  publish(event: AuditEvent): Promise<void>;
}

/** Implementación vacía. Ver el porqué en el encabezado del archivo. */
export class NullAuditPublisher implements AuditPublisher {
  async publish(_event: AuditEvent): Promise<void> {
    return;
  }
}

export const auditPublisher: AuditPublisher = new NullAuditPublisher();
