/**
 * Narrow DTOs for the checkout feature (RFC-006 sections 31/39).
 *
 * These are deliberately NOT `Tables<"orders">`/`Tables<"order_items">` -
 * same rationale as `src/features/events/public/types.ts`: a narrow,
 * hand-declared shape can never accidentally widen to include a column
 * (customer internal fields, `checkout_token_hash`, payment secrets,
 * internal organization metadata) just because it exists on the full row.
 */

export type CheckoutLineItem = {
  ticketTypeId: string;
  name: string;
  quantity: number;
  /** Integer minor units - see src/lib/money.ts. */
  unitPriceMinor: number;
  /** Integer minor units - unitPriceMinor * quantity, computed authoritatively by the database. */
  lineTotalMinor: number;
};

/**
 * The exact response shape `POST /api/checkout` returns (RFC-006 section
 * 31). `checkoutToken` is the RAW token - present in this ONE response,
 * never persisted, never returned again by any other endpoint (see
 * src/lib/checkout/token.ts and get_checkout_order, which only ever
 * receives/compares the hash).
 */
export type CheckoutResponse = {
  orderId: string;
  checkoutToken: string;
  status: "PENDING_PAYMENT";
  /** ISO 8601 timestamp - when the ticket_holds reservation lapses. Server-generated; never derived from client input. */
  expiresAt: string;
  currency: string;
  subtotalMinor: number;
  totalMinor: number;
  items: CheckoutLineItem[];
};

/**
 * The checkout continuation page's data (RFC-006 sections 26/27/39),
 * returned by `get_checkout_order`. `orderStatus` may already read
 * `"EXPIRED"` even if the buyer only just navigated here - see the
 * migration's timestamp-aware derivation; the page must not assume
 * `"PENDING_PAYMENT"` just because it hasn't seen an expiry.
 */
export type CheckoutOrderView = {
  orderId: string;
  orderStatus: string;
  expiresAt: string;
  currency: string;
  subtotalMinor: number;
  totalMinor: number;
  event: {
    name: string;
    startsAt: string;
    venueName: string | null;
  };
  organization: {
    name: string;
    timezone: string;
  };
  items: CheckoutLineItem[];
};
