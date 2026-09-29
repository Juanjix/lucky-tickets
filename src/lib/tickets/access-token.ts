import "server-only";

import { createHmac, timingSafeEqual } from "node:crypto";

import { getTicketServerEnv } from "@/lib/env/server";

/**
 * The buyer's ticket-access capability (RFC-008).
 *
 * Deliberately NOT a reuse of RFC-006/007's checkout token:
 * `src/features/payments/api.ts` already documents, as an accepted
 * RFC-007 tradeoff, that the raw checkout token travels inside Mercado
 * Pago's `back_urls` and is therefore retained by a third party. That
 * exposure is acceptable for a short-lived "check my payment status"
 * credential; it is NOT acceptable for a long-lived credential that
 * unlocks scannable venue-entry QR codes. This module mints a completely
 * separate value that never leaves Lucky Ticket's own servers until it is
 * handed to the buyer directly (never round-tripped through a third
 * party's redirect URL).
 *
 * It is a STATELESS, deterministic HMAC-SHA256 of the order id, keyed by
 * a fixed server-only secret (`getTicketServerEnv().TICKET_ACCESS_SIGNING_KEY`).
 * No database storage, no minting step, no race: any trusted server
 * request - the payment-status poll that first observes PAID, or the
 * buyer reopening the tickets page a week later - can independently
 * recompute and verify the exact same value at any time. This
 * specifically avoids the unrecoverable-lockout race a stored-random-token
 * design would create (the webhook handler that would mint such a token
 * has no channel back to the buyer's browser to deliver it).
 *
 * This is a capability, not a login: knowing the order id AND this token
 * is what authorizes reading that one order's tickets - see
 * `src/features/tickets/queries.ts` (`getOrderTicketsForBuyer`), which
 * verifies it BEFORE ever calling the service-role-only `get_order_tickets`
 * database function (RFC-008 migration). An order id alone is never
 * sufficient.
 */

function computeTicketAccessToken(orderId: string): string {
  const { TICKET_ACCESS_SIGNING_KEY } = getTicketServerEnv();
  return createHmac("sha256", TICKET_ACCESS_SIGNING_KEY)
    .update(`order:${orderId}`, "utf8")
    .digest("hex");
}

/** Computes the buyer's ticket-access token for orderId. Safe to call repeatedly/from multiple processes - it is a pure function of the order id and a fixed server secret, never stored. */
export function getTicketAccessToken(orderId: string): string {
  return computeTicketAccessToken(orderId);
}

/**
 * Verifies a candidate ticket-access token against orderId using a
 * constant-time comparison (`timingSafeEqual`) - never `===`, which would
 * leak timing information about how many leading bytes matched.
 * Mismatched lengths (e.g. a garbage/truncated query param) are handled
 * explicitly since `timingSafeEqual` throws rather than returning false
 * for differing buffer lengths.
 */
export function verifyTicketAccessToken(
  orderId: string,
  candidate: string | null | undefined,
): boolean {
  if (!candidate) {
    return false;
  }

  const expected = Buffer.from(computeTicketAccessToken(orderId), "hex");
  const provided = Buffer.from(candidate, "hex");

  if (expected.length !== provided.length) {
    return false;
  }

  return timingSafeEqual(expected, provided);
}
