import "server-only";

import { cache } from "react";

import { AppError } from "@/lib/errors/app-error";
import { createPublicClient } from "@/lib/supabase/public";

import { deriveTicketAvailability } from "./availability";
import type { PublicEventPage } from "./types";

/**
 * The public read boundary for the buyer-facing event page (RFC-005).
 *
 * Every query below runs through `createPublicClient()`, which never
 * carries a session/cookies and therefore always executes as `anon` at
 * the database (see
 * supabase/migrations/20260923000000_rfc_005_public_event_access.sql for
 * the RLS policies this relies on). This function must never be called
 * with an authenticated Supabase client - the point of the public
 * boundary is that it behaves identically for every visitor, logged in or
 * not.
 *
 * Returns `null` for every case the buyer should not be able to tell
 * apart: a nonexistent organization slug, a nonexistent event slug, an
 * event that exists but is not PUBLISHED, or an event that exists under a
 * DIFFERENT organization than the one in the URL. Callers render
 * `notFound()` uniformly for a `null` result - RFC-005 "Error / not-found
 * behavior" is explicit that the public route must not leak which of
 * these it was.
 *
 * Each database row is mapped into the narrow `PublicEventPage` DTO
 * (`src/features/events/public/types.ts`) rather than returned as-is -
 * "Organizer Event model ≠ Public Event DTO" (RFC-005 "Public data access
 * architecture"). Internal ids (`organizations.id`, `events.id`) are read
 * only to perform the tenant-scoped joins below and are never included in
 * the returned shape (`ticket_types.id` is the one exception - kept
 * because RFC-006's future ticket selection needs a stable identifier for
 * "which ticket type").
 *
 * Wrapped in React's `cache()` so `generateMetadata` and the page
 * component (both of which need this same data) share one database
 * round-trip per request instead of querying twice - this is request-scoped
 * memoization only, not caching across requests or visitors: every new
 * request re-runs the query from scratch, so an organizer's edit is
 * reflected on the very next page load (RFC-005 "Caching": "Prefer
 * correctness for the MVP"). No `revalidate`/ISR is configured anywhere on
 * this route for the same reason.
 */
export const getPublicEvent = cache(async function getPublicEvent(
  organizationSlug: string,
  eventSlug: string,
): Promise<PublicEventPage | null> {
  const supabase = createPublicClient();

  const { data: organizationRow, error: organizationError } = await supabase
    .from("organizations")
    .select("id, name, slug, timezone")
    .eq("slug", organizationSlug)
    .maybeSingle();

  if (organizationError) {
    throw new AppError("internal", "Failed to load organization.", {
      cause: organizationError,
    });
  }

  if (!organizationRow) {
    return null;
  }

  const { data: eventRow, error: eventError } = await supabase
    .from("events")
    .select(
      "id, name, slug, description, venue_name, venue_address, starts_at, ends_at, capacity",
    )
    // Both filters matter: `organization_id` is what makes "this event
    // slug, but the wrong organization" return nothing (RFC-005 "wrong
    // organization/event slug combination returns no public record"),
    // rather than accidentally matching some other org's event with the
    // same slug - `events_org_slug_key` only guarantees the slug is
    // unique WITHIN an organization, not globally.
    .eq("organization_id", organizationRow.id)
    .eq("slug", eventSlug)
    .maybeSingle();

  if (eventError) {
    throw new AppError("internal", "Failed to load event.", {
      cause: eventError,
    });
  }

  if (!eventRow) {
    return null;
  }

  const { data: ticketTypeRows, error: ticketTypesError } = await supabase
    .from("ticket_types")
    .select(
      "id, name, description, unit_price_amount, currency, sales_start_at, sales_end_at, max_per_order",
    )
    .eq("organization_id", organizationRow.id)
    .eq("event_id", eventRow.id)
    .order("sort_order", { ascending: true });

  if (ticketTypesError) {
    throw new AppError("internal", "Failed to load ticket types.", {
      cause: ticketTypesError,
    });
  }

  // RFC-006 section 37/38: the public page has zero direct visibility into
  // orders/order_items/ticket_holds (and must not gain any) - this RPC is
  // the one authoritative, narrow source for "is this ticket type sold
  // out", returning only a boolean per ticket type id.
  const { data: availabilityRows, error: availabilityError } = await supabase
    .rpc("get_public_ticket_availability", { p_event_id: eventRow.id });

  if (availabilityError) {
    throw new AppError("internal", "Failed to load ticket availability.", {
      cause: availabilityError,
    });
  }

  const soldOutByTicketTypeId = new Map(
    (availabilityRows ?? []).map((row) => [row.ticket_type_id, row.is_sold_out]),
  );

  return {
    organization: {
      name: organizationRow.name,
      slug: organizationRow.slug,
      timezone: organizationRow.timezone,
    },
    event: {
      name: eventRow.name,
      slug: eventRow.slug,
      description: eventRow.description,
      venueName: eventRow.venue_name,
      venueAddress: eventRow.venue_address,
      startsAt: eventRow.starts_at,
      endsAt: eventRow.ends_at,
      capacity: eventRow.capacity,
    },
    ticketTypes: (ticketTypeRows ?? []).map((ticketType) => ({
      id: ticketType.id,
      name: ticketType.name,
      description: ticketType.description,
      priceMinor: ticketType.unit_price_amount,
      currency: ticketType.currency,
      salesStartAt: ticketType.sales_start_at,
      salesEndAt: ticketType.sales_end_at,
      maxPerOrder: ticketType.max_per_order,
      availability: deriveTicketAvailability(
        {
          salesStartAt: ticketType.sales_start_at,
          salesEndAt: ticketType.sales_end_at,
        },
        soldOutByTicketTypeId.get(ticketType.id) ?? false,
      ),
    })),
  };
});
