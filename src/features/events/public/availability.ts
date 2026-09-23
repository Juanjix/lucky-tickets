import type { TicketAvailability } from "./types";

/**
 * Derives a buyer-facing sales state from a ticket type's sales window -
 * centralized here per RFC-005 "Sales window" ("Centralize this
 * derivation rather than duplicating date logic across components")
 * rather than being computed inline wherever a ticket type is rendered.
 *
 * This NEVER mutates or persists anything - `sales_start_at`/`sales_end_at`
 * stay exactly as RFC-004 defined them; only the buyer-facing label is
 * computed, and only from the current time.
 *
 * `now` defaults to `new Date()` but is a parameter so this stays a pure,
 * easily-testable function - a Server Component can call it with a fixed
 * `now` to keep a render deterministic if that ever matters.
 */
export function deriveTicketAvailability(
  ticketType: {
    salesStartAt: string | null;
    salesEndAt: string | null;
  },
  now: Date = new Date(),
): TicketAvailability {
  if (ticketType.salesStartAt && new Date(ticketType.salesStartAt) > now) {
    return "UPCOMING";
  }

  if (ticketType.salesEndAt && new Date(ticketType.salesEndAt) <= now) {
    return "ENDED";
  }

  return "AVAILABLE";
}
