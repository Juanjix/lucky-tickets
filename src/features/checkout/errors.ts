/**
 * Stable checkout domain errors (RFC-006 section 32).
 *
 * `create_order_with_hold` and `get_checkout_order`
 * (supabase/migrations/20260924000000_rfc_006_orders_inventory.sql) raise
 * plain Postgres exceptions with a custom SQLSTATE (`LT001`-`LT009`) for
 * every expected business failure - never a raw/parsed error message. This
 * module is the ONE place that SQLSTATE -> `CheckoutErrorCode` mapping
 * happens; nothing else in the checkout feature should inspect
 * `error.code`/`error.message` from a Postgres/PostgREST error directly.
 *
 * `ORDER_EXPIRED` is listed here because RFC-006 section 32 requires it to
 * exist as a stable code, but the database never raises it as an
 * exception: `get_checkout_order` instead reports an expired order by
 * returning `orderStatus: "EXPIRED"` inside a NORMAL (non-error) response
 * (see the migration's `case when ... then 'EXPIRED'` derivation) - the
 * checkout page reads that status, not a caught error. `ORDER_EXPIRED` is
 * reserved for a future RFC-007 caller (e.g. attempting to start a payment
 * against an already-expired order) that DOES need to reject with an
 * error rather than merely display a status.
 */

export const CHECKOUT_ERROR_CODES = [
  "EVENT_NOT_AVAILABLE",
  "TICKET_TYPE_NOT_AVAILABLE",
  "SALES_NOT_STARTED",
  "SALES_ENDED",
  "INSUFFICIENT_INVENTORY",
  "INVALID_QUANTITY",
  "ORDER_EXPIRED",
  "INVALID_CHECKOUT_TOKEN",
  "CHECKOUT_LIMIT_EXCEEDED",
  /**
   * Not one of RFC-006's nine named domain errors - used for a
   * structurally invalid request (fails Zod) or any database failure that
   * did not carry one of the known LTxxx codes. Always maps to a generic,
   * safe message; never echoes the underlying error to the client (RFC-006
   * section 32: "Do not send raw Postgres errors to the browser").
   */
  "UNKNOWN",
] as const;

export type CheckoutErrorCode = (typeof CHECKOUT_ERROR_CODES)[number];

/** Postgres SQLSTATE (as raised by the RFC-006 migration's `using errcode = 'LTxxx'`) -> stable application error code. */
const SQLSTATE_TO_CHECKOUT_ERROR: Record<string, CheckoutErrorCode> = {
  LT001: "EVENT_NOT_AVAILABLE",
  LT002: "TICKET_TYPE_NOT_AVAILABLE",
  LT003: "SALES_NOT_STARTED",
  LT004: "SALES_ENDED",
  LT005: "INSUFFICIENT_INVENTORY",
  LT006: "INVALID_QUANTITY",
  LT008: "INVALID_CHECKOUT_TOKEN",
  LT009: "CHECKOUT_LIMIT_EXCEEDED",
};

/** HTTP status for each domain error (RFC-006 section 33). */
const HTTP_STATUS_BY_CHECKOUT_ERROR: Record<CheckoutErrorCode, number> = {
  EVENT_NOT_AVAILABLE: 404,
  // Not found rather than a validation error: a ticket type id the caller
  // supplied doesn't resolve for this event/organization, or fails a
  // visibility/active check - conceptually "no such purchasable ticket".
  TICKET_TYPE_NOT_AVAILABLE: 404,
  SALES_NOT_STARTED: 409,
  SALES_ENDED: 409,
  INSUFFICIENT_INVENTORY: 409,
  INVALID_QUANTITY: 400,
  ORDER_EXPIRED: 410,
  // 404, not 401/403: confirming "the token is wrong" (vs. "no such
  // order") for a resource this sensitive would itself be a leak (RFC-006
  // section 33: "Do not leak security-sensitive distinctions when it would
  // reveal private resources").
  INVALID_CHECKOUT_TOKEN: 404,
  CHECKOUT_LIMIT_EXCEEDED: 400,
  UNKNOWN: 500,
};

/** User-safe message for each domain error - never derived from the raw Postgres/Zod message. */
const PUBLIC_MESSAGE_BY_CHECKOUT_ERROR: Record<CheckoutErrorCode, string> = {
  EVENT_NOT_AVAILABLE: "This event is not available for purchase.",
  TICKET_TYPE_NOT_AVAILABLE: "That ticket type is not available.",
  SALES_NOT_STARTED: "Sales for this ticket type haven't started yet.",
  SALES_ENDED: "Sales for this ticket type have ended.",
  INSUFFICIENT_INVENTORY:
    "Not enough tickets are available for your request. Please lower the quantity.",
  INVALID_QUANTITY: "The requested ticket quantities are invalid.",
  ORDER_EXPIRED: "This order's reservation has expired.",
  INVALID_CHECKOUT_TOKEN: "This checkout link is invalid or has expired.",
  CHECKOUT_LIMIT_EXCEEDED: "You've exceeded the maximum tickets per order.",
  UNKNOWN: "Something went wrong while processing your checkout.",
};

export class CheckoutError extends Error {
  readonly code: CheckoutErrorCode;
  readonly status: number;

  constructor(code: CheckoutErrorCode, options?: { cause?: unknown }) {
    super(PUBLIC_MESSAGE_BY_CHECKOUT_ERROR[code], { cause: options?.cause });
    this.name = "CheckoutError";
    this.code = code;
    this.status = HTTP_STATUS_BY_CHECKOUT_ERROR[code];
  }

  get publicMessage(): string {
    return PUBLIC_MESSAGE_BY_CHECKOUT_ERROR[this.code];
  }
}

/**
 * Maps any error thrown by a Supabase RPC call
 * (`create_order_with_hold`/`get_checkout_order`) to a `CheckoutError`.
 * Looks ONLY at `error.code` (the Postgres SQLSTATE, as surfaced by
 * `@supabase/supabase-js`/PostgREST) - never parses `error.message` text,
 * which is not a stable contract. Any code not in the known LTxxx set
 * (including a genuinely unexpected database failure) becomes `UNKNOWN`
 * and is logged server-side by the caller, never echoed to the client.
 */
export function toCheckoutError(error: unknown): CheckoutError {
  const code =
    error && typeof error === "object" && "code" in error
      ? String((error as { code: unknown }).code)
      : undefined;

  const mapped = code ? SQLSTATE_TO_CHECKOUT_ERROR[code] : undefined;

  return new CheckoutError(mapped ?? "UNKNOWN", { cause: error });
}
