import "server-only";

import { AppError } from "@/lib/errors/app-error";
import type { SupabaseServerClient } from "@/lib/supabase/server";
import type { Tables } from "@/types/database";

export type EventRow = Tables<"events">;
export type TicketTypeRow = Tables<"ticket_types">;

/**
 * Every event belonging to organizationId, most recently starting first.
 * Scoped by an explicit `organization_id` filter in addition to RLS
 * (`events_select_member`) - defense in depth, not redundancy: this
 * function must only ever be called with an `organizationId` resolved
 * server-side by `requireOrganizationMembership`, never one taken from the
 * client, per RFC-004's "never trust organizationId from the browser."
 * Reads PostgreSQL/RLS-filtered rows directly rather than fetching
 * everything and filtering in application memory.
 */
export async function listOrganizationEvents(
  supabase: SupabaseServerClient,
  organizationId: string,
): Promise<EventRow[]> {
  const { data, error } = await supabase
    .from("events")
    .select("*")
    .eq("organization_id", organizationId)
    .order("starts_at", { ascending: false });

  if (error) {
    throw new AppError("internal", "Failed to load events.", {
      cause: error,
    });
  }

  return data ?? [];
}

/**
 * A single event, or `null` if it doesn't exist or doesn't belong to
 * `organizationId` - the two cases are indistinguishable on purpose (see
 * `requireOrganizationMembership`'s "Routing decision" for why not leaking
 * existence matters), so callers should render `notFound()` for either.
 */
export async function getOrganizationEvent(
  supabase: SupabaseServerClient,
  organizationId: string,
  eventId: string,
): Promise<EventRow | null> {
  const { data, error } = await supabase
    .from("events")
    .select("*")
    .eq("organization_id", organizationId)
    .eq("id", eventId)
    .maybeSingle();

  if (error) {
    throw new AppError("internal", "Failed to load event.", {
      cause: error,
    });
  }

  return data;
}

/** Every ticket type for eventId, in the organizer's own display order. */
export async function getEventTicketTypes(
  supabase: SupabaseServerClient,
  organizationId: string,
  eventId: string,
): Promise<TicketTypeRow[]> {
  const { data, error } = await supabase
    .from("ticket_types")
    .select("*")
    .eq("organization_id", organizationId)
    .eq("event_id", eventId)
    .order("sort_order", { ascending: true });

  if (error) {
    throw new AppError("internal", "Failed to load ticket types.", {
      cause: error,
    });
  }

  return data ?? [];
}
