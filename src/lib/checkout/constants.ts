/**
 * Centralized checkout constants (RFC-006 section 9/16).
 *
 * These values are duplicated, deliberately, in exactly one other place:
 * `supabase/migrations/20260924000000_rfc_006_orders_inventory.sql`, inside
 * `create_order_with_hold` (`v_hold_minutes constant int := 10` and
 * `v_max_tickets_per_order constant int := 10`). PostgreSQL is the
 * authoritative enforcement point for both values - the browser cannot set
 * `expires_at` and the database independently re-validates the cart size
 * regardless of what Zod already checked - so these TypeScript constants
 * exist only to keep the *client-side* UX (form limits, copy, the
 * pre-submit Zod schema) honest with what the database will actually do,
 * not to enforce either rule themselves. If either number ever changes, it
 * must change in both places; there is no shared build-time source for a
 * SQL constant and a TypeScript constant to both import from.
 */

/** Minutes a ticket_holds reservation stays active after order creation. */
export const CHECKOUT_HOLD_MINUTES = 10;

/** Maximum total ticket quantity (summed across all lines) per order. */
export const MAX_TICKETS_PER_ORDER = 10;

/** Maximum number of distinct ticket type lines accepted in one cart. */
export const MAX_CHECKOUT_LINES = 20;
