/**
 * The public DTO shapes for the buyer-facing event page (RFC-005).
 *
 * These are intentionally NOT `Tables<"events">` / `Tables<"ticket_types">`
 * / `Tables<"organizations">` (the organizer-facing row types in
 * `src/features/events/queries.ts`). RFC-005's "Public data access
 * architecture" is explicit that "Organizer Event model ≠ Public Event
 * DTO" - a public page bug should not be able to widen what it renders
 * just by reaching for a field that happens to exist on the full row, so
 * these types only declare what the public contract actually needs. See
 * `src/features/events/public/queries.ts` for what maps a database row
 * into one of these.
 */

/**
 * `SOLD_OUT` was added by RFC-006 (section 37) alongside the other three,
 * which RFC-005 already established. It is derived ONLY from
 * `get_public_ticket_availability`'s authoritative `is_sold_out` signal
 * (RFC-006 section 38) - never inferred from UI state, and never computed
 * by counting anything the public page can see on its own (`anon` has no
 * visibility into orders/order_items/ticket_holds).
 */
export type TicketAvailability = "UPCOMING" | "AVAILABLE" | "SOLD_OUT" | "ENDED";

export type PublicOrganization = {
  name: string;
  slug: string;
  /** IANA timezone, e.g. "America/Argentina/Buenos_Aires" - needed to render event times correctly, not sensitive. */
  timezone: string;
};

export type PublicTicketType = {
  /**
   * Kept (unlike event/organization internal ids) because RFC-006's future
   * ticket selection needs a stable identifier for "which ticket type" -
   * RFC-005's own guidance excludes internal ids "unless operationally
   * required", and this one is. It is never rendered as visible text.
   */
  id: string;
  name: string;
  description: string | null;
  /** Integer minor units - see src/lib/money.ts. Never a float. */
  priceMinor: number;
  currency: string;
  salesStartAt: string | null;
  salesEndAt: string | null;
  /** Derived, not persisted - see src/features/events/public/availability.ts. */
  availability: TicketAvailability;
  /**
   * The most tickets a single checkout may request of this ticket type
   * (RFC-004's `ticket_types.max_per_order`, RFC-006 section 16). Shown to
   * the buyer as a selection ceiling for UX only - `create_order_with_hold`
   * independently re-enforces it server-side regardless of what the
   * browser sends (RFC-006 section 3.1).
   */
  maxPerOrder: number;
};

export type PublicEvent = {
  name: string;
  slug: string;
  description: string | null;
  venueName: string | null;
  venueAddress: string | null;
  startsAt: string;
  endsAt: string | null;
  /**
   * RFC-004's configured capacity - deliberately NOT rendered as a live
   * "X tickets remaining" figure (RFC-005 "Important inventory rule": that
   * accounting belongs to RFC-006). Exposed only because a future RFC-006
   * availability display may need it as an input; today's UI does not use
   * it to claim anything about live availability.
   */
  capacity: number | null;
};

export type PublicEventPage = {
  organization: PublicOrganization;
  event: PublicEvent;
  ticketTypes: PublicTicketType[];
};
