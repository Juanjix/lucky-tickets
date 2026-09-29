/**
 * Narrow DTOs for the payments feature (RFC-007).
 */

/** `POST /api/payments/mercado-pago/preference`'s response shape (RFC-007 section 12). Only the redirect URL - never a preference id, never provider internals. */
export type CreatePreferenceResponse = {
  checkoutUrl: string;
};

/**
 * The 4-value coarse status `GET /api/orders/[orderId]/payment-status`
 * returns (RFC-007 section 45) - deliberately narrower than the full
 * `order_status` enum. `CANCELLED`/`REFUNDED`/`PARTIALLY_REFUNDED` are
 * folded into one of these four so the result page never needs to handle
 * a case RFC-007 section 18 didn't specify; see
 * src/features/payments/queries.ts for the exact folding and its
 * rationale.
 */
export const PAYMENT_STATUS_VALUES = [
  "PENDING_PAYMENT",
  "PAID",
  "PAYMENT_FAILED",
  "EXPIRED",
] as const;

export type PublicPaymentStatus = (typeof PAYMENT_STATUS_VALUES)[number];

export type PaymentStatusResponse = {
  orderId: string;
  status: PublicPaymentStatus;
  /**
   * RFC-008: the buyer's "view my tickets" link, present ONLY once
   * `status` has folded to `PAID` (never for PENDING_PAYMENT/
   * PAYMENT_FAILED/EXPIRED - there is nothing to view yet). Deliberately
   * piggy-backs on this SAME existing polling response rather than a new
   * endpoint (RFC-007's own "reuse existing infrastructure" precedent) -
   * see src/features/payments/queries.ts's getPaymentStatus.
   */
  ticketsUrl?: string;
};
