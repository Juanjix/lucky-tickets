"use server";

import type { PostgrestError } from "@supabase/supabase-js";
import { revalidatePath } from "next/cache";

import { toMinorUnits } from "@/lib/money";
import { slugify } from "@/lib/slug";
import { createClient } from "@/lib/supabase/server";

import { requireEventManager } from "./permissions";
import { getPublishIssues } from "./publish-rules";
import { getEventTicketTypes, getOrganizationEvent } from "./queries";
import {
  createEventSchema,
  createTicketTypeSchema,
  updateEventSchema,
  updateTicketTypeSchema,
} from "./schemas";

export type EventActionResult =
  | { status: "error"; error: string }
  | { status: "success" }
  | { status: "redirect"; redirectTo: string };

const MAX_SLUG_ATTEMPTS = 5;

function isUniqueSlugViolation(error: PostgrestError): boolean {
  return (
    error.code === "23505" && error.message.includes("events_org_slug_key")
  );
}

/**
 * Creates a DRAFT event with the minimum information the database actually
 * requires (name, start date) - RFC-004 "Event creation" explicitly says
 * not to force full configuration up front; venue, description, capacity,
 * and ticket types are all added afterward from the event management page.
 * The slug is computed here, server-side, from the name (never trusted
 * from the client) and scoped to this organization
 * (`events_org_slug_key`), with the same generate-then-retry-on-collision
 * pattern `create_organization` uses for organization slugs (RFC-003) -
 * this is a single-table insert, so the retry loop lives here in
 * application code rather than needing a database function for atomicity.
 */
export async function createEventAction(
  organizationSlug: string,
  input: unknown,
): Promise<EventActionResult> {
  const { organization } = await requireEventManager(organizationSlug);

  const parsed = createEventSchema.safeParse(input);

  if (!parsed.success) {
    return {
      status: "error",
      error: parsed.error.issues[0]?.message ?? "Invalid event details.",
    };
  }

  const baseSlug = slugify(parsed.data.name);

  if (!baseSlug) {
    return {
      status: "error",
      error:
        "That name doesn't produce a usable URL. Try including a letter or number.",
    };
  }

  const supabase = await createClient();
  let slug = baseSlug;

  for (let attempt = 1; attempt <= MAX_SLUG_ATTEMPTS; attempt += 1) {
    const { data: event, error } = await supabase
      .from("events")
      .insert({
        organization_id: organization.id,
        name: parsed.data.name,
        slug,
        starts_at: parsed.data.startsAt,
      })
      .select()
      .single();

    if (!error) {
      revalidatePath(`/dashboard/${organizationSlug}/events`);
      return {
        status: "redirect",
        redirectTo: `/dashboard/${organizationSlug}/events/${event.id}`,
      };
    }

    if (isUniqueSlugViolation(error) && attempt < MAX_SLUG_ATTEMPTS) {
      slug = `${baseSlug}-${attempt + 1}`;
      continue;
    }

    return {
      status: "error",
      error: "Could not create the event. Please try again.",
    };
  }

  return {
    status: "error",
    error: "Could not create the event. Please try again.",
  };
}

/**
 * Updates an event's own details (not its ticket types, not its
 * publication status - see `publishEventAction` for that). Tenant-scoped
 * by an explicit `organization_id` filter resolved server-side from the
 * URL's `organizationSlug`, never from `eventId` alone.
 */
export async function updateEventAction(
  organizationSlug: string,
  eventId: string,
  input: unknown,
): Promise<EventActionResult> {
  const { organization } = await requireEventManager(organizationSlug);

  const parsed = updateEventSchema.safeParse(input);

  if (!parsed.success) {
    return {
      status: "error",
      error: parsed.error.issues[0]?.message ?? "Invalid event details.",
    };
  }

  const supabase = await createClient();

  const { data, error } = await supabase
    .from("events")
    .update({
      name: parsed.data.name,
      description: parsed.data.description || null,
      venue_name: parsed.data.venueName || null,
      venue_address: parsed.data.venueAddress || null,
      starts_at: parsed.data.startsAt,
      ends_at: parsed.data.endsAt || null,
      capacity: parsed.data.capacity ? Number(parsed.data.capacity) : null,
    })
    .eq("organization_id", organization.id)
    .eq("id", eventId)
    .select("id")
    .maybeSingle();

  if (error) {
    if (error.code === "23514") {
      return {
        status: "error",
        error:
          "That change isn't valid - check the dates and capacity against the event's configured ticket types.",
      };
    }

    return {
      status: "error",
      error: "Could not update the event. Please try again.",
    };
  }

  if (!data) {
    return { status: "error", error: "Event not found." };
  }

  revalidatePath(`/dashboard/${organizationSlug}/events/${eventId}`);
  revalidatePath(`/dashboard/${organizationSlug}/events`);
  return { status: "success" };
}

/**
 * Adds a ticket type to an event. The event is re-fetched, tenant-scoped,
 * before the insert - not just to let RLS/the composite FK reject a
 * mismatched `eventId`, but to fail with a clean error instead of a raw
 * database one (same rationale as RFC-003's `requireUser` check ahead of
 * its RPC). The organizer enters a price in major units; `toMinorUnits`
 * converts it before it ever reaches the database - see src/lib/money.ts.
 * Currency always follows the organization's own currency (RFC-004
 * "Ticket Types": "use the existing organization/event currency model"),
 * never a client-supplied value.
 */
export async function createTicketTypeAction(
  organizationSlug: string,
  eventId: string,
  input: unknown,
): Promise<EventActionResult> {
  const { organization } = await requireEventManager(organizationSlug);

  const parsed = createTicketTypeSchema.safeParse(input);

  if (!parsed.success) {
    return {
      status: "error",
      error: parsed.error.issues[0]?.message ?? "Invalid ticket type details.",
    };
  }

  const supabase = await createClient();
  const event = await getOrganizationEvent(supabase, organization.id, eventId);

  if (!event) {
    return { status: "error", error: "Event not found." };
  }

  const { error } = await supabase.from("ticket_types").insert({
    organization_id: organization.id,
    event_id: eventId,
    name: parsed.data.name,
    description: parsed.data.description || null,
    unit_price_amount: toMinorUnits(Number(parsed.data.priceMajor)),
    currency: organization.currency,
    quantity: Number(parsed.data.quantity),
    visibility: parsed.data.visibility,
    sales_start_at: parsed.data.salesStartAt || null,
    sales_end_at: parsed.data.salesEndAt || null,
  });

  if (error) {
    if (error.code === "23514") {
      return {
        status: "error",
        error:
          "This ticket type's quantity would push the event's total inventory past its capacity.",
      };
    }

    return {
      status: "error",
      error: "Could not create the ticket type. Please try again.",
    };
  }

  revalidatePath(`/dashboard/${organizationSlug}/events/${eventId}`);
  return { status: "success" };
}

/** Updates an existing ticket type, tenant-scoped by organization_id. */
export async function updateTicketTypeAction(
  organizationSlug: string,
  ticketTypeId: string,
  input: unknown,
): Promise<EventActionResult> {
  const { organization } = await requireEventManager(organizationSlug);

  const parsed = updateTicketTypeSchema.safeParse(input);

  if (!parsed.success) {
    return {
      status: "error",
      error: parsed.error.issues[0]?.message ?? "Invalid ticket type details.",
    };
  }

  const supabase = await createClient();

  const { data, error } = await supabase
    .from("ticket_types")
    .update({
      name: parsed.data.name,
      description: parsed.data.description || null,
      unit_price_amount: toMinorUnits(Number(parsed.data.priceMajor)),
      quantity: Number(parsed.data.quantity),
      visibility: parsed.data.visibility,
      sales_start_at: parsed.data.salesStartAt || null,
      sales_end_at: parsed.data.salesEndAt || null,
    })
    .eq("organization_id", organization.id)
    .eq("id", ticketTypeId)
    .select("event_id")
    .maybeSingle();

  if (error) {
    if (error.code === "23514") {
      return {
        status: "error",
        error:
          "That change would push the event's inventory past its capacity.",
      };
    }

    return {
      status: "error",
      error: "Could not update the ticket type. Please try again.",
    };
  }

  if (!data) {
    return { status: "error", error: "Ticket type not found." };
  }

  revalidatePath(`/dashboard/${organizationSlug}/events/${data.event_id}`);
  return { status: "success" };
}

/**
 * Removes a ticket type. RFC-002's `order_items_org_ticket_type_fk` is
 * `on delete restrict`, so once RFC-006 introduces real orders, deleting a
 * ticket type that has actually been sold will fail at the database level
 * (23503) automatically, with no change needed here - this action already
 * handles that error today even though it cannot occur yet (RFC-004 does
 * not implement orders), per RFC-004's "design the mutation boundary so
 * stricter rules can be introduced later."
 */
export async function deleteTicketTypeAction(
  organizationSlug: string,
  ticketTypeId: string,
): Promise<EventActionResult> {
  const { organization } = await requireEventManager(organizationSlug);

  const supabase = await createClient();

  const { data, error } = await supabase
    .from("ticket_types")
    .delete()
    .eq("organization_id", organization.id)
    .eq("id", ticketTypeId)
    .select("event_id")
    .maybeSingle();

  if (error) {
    if (error.code === "23503") {
      return {
        status: "error",
        error:
          "This ticket type can't be removed because it has already been used in an order.",
      };
    }

    return {
      status: "error",
      error: "Could not remove the ticket type. Please try again.",
    };
  }

  if (!data) {
    return { status: "error", error: "Ticket type not found." };
  }

  revalidatePath(`/dashboard/${organizationSlug}/events/${data.event_id}`);
  return { status: "success" };
}

/**
 * Publishes an event. Checks the centralized invariants in
 * `publish-rules.ts` first, so the organizer gets one clear, complete list
 * of what's missing - the database's own `enforce_event_publish_invariants()`
 * trigger (RFC-004 migration) is a backstop for this same operation, not
 * the primary source of the error message.
 */
export async function publishEventAction(
  organizationSlug: string,
  eventId: string,
): Promise<EventActionResult> {
  const { organization } = await requireEventManager(organizationSlug);

  const supabase = await createClient();
  const event = await getOrganizationEvent(supabase, organization.id, eventId);

  if (!event) {
    return { status: "error", error: "Event not found." };
  }

  const ticketTypes = await getEventTicketTypes(
    supabase,
    organization.id,
    eventId,
  );

  const issues = getPublishIssues(event, ticketTypes);

  if (issues.length > 0) {
    return { status: "error", error: issues.join(" ") };
  }

  const { data, error } = await supabase
    .from("events")
    .update({ status: "PUBLISHED", published_at: new Date().toISOString() })
    .eq("organization_id", organization.id)
    .eq("id", eventId)
    .select("id")
    .maybeSingle();

  if (error || !data) {
    return {
      status: "error",
      error: "Could not publish the event. Please try again.",
    };
  }

  revalidatePath(`/dashboard/${organizationSlug}/events/${eventId}`);
  revalidatePath(`/dashboard/${organizationSlug}/events`);
  return { status: "success" };
}
