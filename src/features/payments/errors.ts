/**
 * Stable payment domain errors (RFC-007, mirroring
 * src/features/checkout/errors.ts's pattern for RFC-006).
 *
 * `record_payment_preference`
 * (supabase/migrations/20260925000000_rfc_007_mercado_pago.sql) raises
 * plain Postgres exceptions with a custom SQLSTATE - `LT008` (reused from
 * RFC-006, same meaning: invalid checkout token) and `LT011` (new:
 * order is not currently payable) - never a raw/parsed error message.
 * This module is the ONE place that mapping happens for the payments
 * feature.
 */

export const PAYMENT_ERROR_CODES = [
  "INVALID_CHECKOUT_TOKEN",
  "ORDER_NOT_PAYABLE",
  "ORDER_NOT_FOUND",
  "PROVIDER_ERROR",
  "UNKNOWN",
] as const;

export type PaymentErrorCode = (typeof PAYMENT_ERROR_CODES)[number];

/** Postgres SQLSTATE -> stable application error code. */
const SQLSTATE_TO_PAYMENT_ERROR: Record<string, PaymentErrorCode> = {
  LT008: "INVALID_CHECKOUT_TOKEN",
  LT011: "ORDER_NOT_PAYABLE",
  LT010: "ORDER_NOT_FOUND",
};

/** HTTP status for each domain error. */
const HTTP_STATUS_BY_PAYMENT_ERROR: Record<PaymentErrorCode, number> = {
  // Same 404-not-401/403 reasoning as RFC-006's INVALID_CHECKOUT_TOKEN
  // (src/features/checkout/errors.ts): confirming "wrong token" vs. "no
  // such order" would itself leak information about a sensitive resource.
  INVALID_CHECKOUT_TOKEN: 404,
  // 410 Gone - the resource (a payable order) existed but its payable
  // window has passed, mirroring RFC-006's reserved ORDER_EXPIRED code.
  ORDER_NOT_PAYABLE: 410,
  ORDER_NOT_FOUND: 404,
  // 502: the failure is Mercado Pago's API/network, not the caller's
  // request - never surfaced as a 4xx, which would incorrectly suggest
  // the buyer did something wrong.
  PROVIDER_ERROR: 502,
  UNKNOWN: 500,
};

/** User-safe message for each domain error - never derived from a raw Postgres/Mercado Pago error. */
const PUBLIC_MESSAGE_BY_PAYMENT_ERROR: Record<PaymentErrorCode, string> = {
  INVALID_CHECKOUT_TOKEN: "This checkout link is invalid or has expired.",
  ORDER_NOT_PAYABLE: "This order's reservation has expired.",
  ORDER_NOT_FOUND: "We couldn't find that order.",
  PROVIDER_ERROR:
    "We couldn't reach the payment provider. Please try again in a moment.",
  UNKNOWN: "Something went wrong while starting your payment.",
};

export class PaymentError extends Error {
  readonly code: PaymentErrorCode;
  readonly status: number;

  constructor(code: PaymentErrorCode, options?: { cause?: unknown }) {
    super(PUBLIC_MESSAGE_BY_PAYMENT_ERROR[code], { cause: options?.cause });
    this.name = "PaymentError";
    this.code = code;
    this.status = HTTP_STATUS_BY_PAYMENT_ERROR[code];
  }

  get publicMessage(): string {
    return PUBLIC_MESSAGE_BY_PAYMENT_ERROR[this.code];
  }
}

/** Maps any error thrown by `record_payment_preference` to a `PaymentError`. Looks ONLY at `error.code` (the Postgres SQLSTATE), never `error.message`. */
export function toPaymentError(error: unknown): PaymentError {
  const code =
    error && typeof error === "object" && "code" in error
      ? String((error as { code: unknown }).code)
      : undefined;

  const mapped = code ? SQLSTATE_TO_PAYMENT_ERROR[code] : undefined;

  return new PaymentError(mapped ?? "UNKNOWN", { cause: error });
}
