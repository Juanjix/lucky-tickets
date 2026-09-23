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

export type TicketAvailability = "UPCOMING" | "AVAILABLE" | "ENDED";

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
