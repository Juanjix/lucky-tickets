/**
 * Shared application error model.
 *
 * This is a convention, not a framework: a small typed wrapper so future
 * server code (route handlers, Server Actions) can distinguish expected
 * error categories from unexpected ones, and so user-facing messages never
 * leak internal detail. It does not implement any business error — those
 * arrive with the RFC that needs them.
 */

export const APP_ERROR_KINDS = [
  "validation",
  "authentication",
  "authorization",
  "not_found",
  "conflict",
  "external_provider",
  "internal",
] as const;

export type AppErrorKind = (typeof APP_ERROR_KINDS)[number];

const DEFAULT_STATUS_BY_KIND: Record<AppErrorKind, number> = {
  validation: 400,
  authentication: 401,
  authorization: 403,
  not_found: 404,
  conflict: 409,
  external_provider: 502,
  internal: 500,
};

/**
 * Message shown to end users for kinds whose real message must not be
 * exposed (it may describe internal state, a query, or a provider's raw
 * response). Everything else uses the error's own `message`.
 */
const SAFE_PUBLIC_MESSAGE_BY_KIND: Partial<Record<AppErrorKind, string>> = {
  external_provider: "An upstream service failed. Please try again shortly.",
  internal: "Something went wrong on our end.",
};

export class AppError extends Error {
  readonly kind: AppErrorKind;
  readonly status: number;

  constructor(
    kind: AppErrorKind,
    message: string,
    /** `options.cause` is for logs only — never rendered to the user. */
    options?: { status?: number; cause?: unknown },
  ) {
    super(message, { cause: options?.cause });
    this.name = "AppError";
    this.kind = kind;
    this.status = options?.status ?? DEFAULT_STATUS_BY_KIND[kind];
  }

  /** The message safe to send to an end user for this error. */
  get publicMessage(): string {
    return SAFE_PUBLIC_MESSAGE_BY_KIND[this.kind] ?? this.message;
  }
}
