import type { TicketAvailability } from "./types";

/**
 * Derives a buyer-facing sales state from a ticket type's sales window and
 * an authoritative sold-out signal - centralized here per RFC-005 "Sales
 * window" ("Centralize this derivation rather than duplicating date logic
 * across components") rather than being computed inline wherever a ticket
 * type is rendered.
 *
 * This NEVER mutates or persists anything - `sales_start_at`/`sales_end_at`
 * stay exactly as RFC-004 defined them; only the buyer-facing label is
 * computed. `isSoldOut` (RFC-006 section 37/38) must come from
 * `get_public_ticket_availability` - the one authoritative source for
 * inventory state on the public page - never inferred or guessed here.
 *
 * Precedence: a ticket type outside its sales window is UPCOMING/ENDED
 * regardless of `isSoldOut` (there is no inventory concern before sales
 * start or after they end); only a ticket type that IS currently
 * temporally available can be SOLD_OUT.
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
  isSoldOut: boolean,
  now: Date = new Date(),
): TicketAvailability {
  if (ticketType.salesStartAt && new Date(ticketType.salesStartAt) > now) {
    return "UPCOMING";
  }

  if (ticketType.salesEndAt && new Date(ticketType.salesEndAt) <= now) {
    return "ENDED";
  }

  if (isSoldOut) {
    return "SOLD_OUT";
  }

  return "AVAILABLE";
}
