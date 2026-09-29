import { notFound } from "next/navigation";

import { EventDetailsForm } from "@/features/events/components/event-details-form";
import { PublishPanel } from "@/features/events/components/publish-panel";
import { TicketTypesManager } from "@/features/events/components/ticket-types-manager";
import { EVENT_MANAGER_ROLES } from "@/features/events/permissions";
import { getPublishIssues } from "@/features/events/publish-rules";
import {
  getEventTicketTypes,
  getOrganizationEvent,
} from "@/features/events/queries";
import { listEventTickets } from "@/features/tickets/queries";
import { requireOrganizationMembership } from "@/lib/auth/require-organization";
import { createClient } from "@/lib/supabase/server";

/**
 * The event management page: details, ticket types, and publication
 * status, kept as three clearly separated sections on one page rather
 * than a separate /edit route - RFC-004 "Event detail / management page"
 * prefers a simple architecture over more routes. Membership alone (any
 * role) is enough to view this page; `canManage` gates which sections
 * render editable controls versus a read-only view - the actual
 * authorization boundary is in the Server Actions this page's components
 * call (`requireEventManager`) and in RLS, not in this conditional.
 */
export default async function EventDetailPage(
  props: PageProps<"/dashboard/[organizationSlug]/events/[eventId]">,
) {
  const { organizationSlug, eventId } = await props.params;
  const { organization, membership } =
    await requireOrganizationMembership(organizationSlug);

  const supabase = await createClient();
  const event = await getOrganizationEvent(supabase, organization.id, eventId);

  if (!event) {
    notFound();
  }

  const ticketTypes = await getEventTicketTypes(
    supabase,
    organization.id,
    eventId,
  );

  // RFC-008: a basic operational list - never the raw QR token, the QR
  // ciphertext, or any buyer-access/checkout secret. See
  // src/features/tickets/queries.ts's listEventTickets doc comment.
  const issuedTickets = await listEventTickets(
    supabase,
    organization.id,
    eventId,
  );
  const ticketTypeNameById = new Map(ticketTypes.map((tt) => [tt.id, tt.name]));

  const canManage = (EVENT_MANAGER_ROLES as readonly string[]).includes(
    membership.role,
  );

  const publishIssues = getPublishIssues(event, ticketTypes);

  return (
    <div className="flex flex-col gap-8">
      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
          {event.name}
        </h1>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          {new Date(event.starts_at).toLocaleString()}
          {event.venue_name ? ` · ${event.venue_name}` : ""}
        </p>
      </div>

      <PublishPanel
        organizationSlug={organizationSlug}
        event={event}
        issues={publishIssues}
        canManage={canManage}
      />

      <section className="flex flex-col gap-4">
        <h2 className="text-lg font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
          Event details
        </h2>
        {canManage ? (
          <EventDetailsForm organizationSlug={organizationSlug} event={event} />
        ) : (
          <dl className="grid gap-3 text-sm sm:grid-cols-2">
            <div>
              <dt className="text-zinc-500 dark:text-zinc-500">Description</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">
                {event.description || "—"}
              </dd>
            </div>
            <div>
              <dt className="text-zinc-500 dark:text-zinc-500">Venue</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">
                {event.venue_name || "—"}
                {event.venue_address ? `, ${event.venue_address}` : ""}
              </dd>
            </div>
            <div>
              <dt className="text-zinc-500 dark:text-zinc-500">Ends at</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">
                {event.ends_at ? new Date(event.ends_at).toLocaleString() : "—"}
              </dd>
            </div>
            <div>
              <dt className="text-zinc-500 dark:text-zinc-500">Capacity</dt>
              <dd className="text-zinc-900 dark:text-zinc-100">
                {event.capacity ?? "No cap"}
              </dd>
            </div>
          </dl>
        )}
      </section>

      <section className="flex flex-col gap-4">
        <h2 className="text-lg font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
          Ticket types
        </h2>
        <TicketTypesManager
          organizationSlug={organizationSlug}
          eventId={event.id}
          currency={organization.currency}
          ticketTypes={ticketTypes}
          canManage={canManage}
        />
      </section>

      <section className="flex flex-col gap-4">
        <h2 className="text-lg font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
          Issued tickets
        </h2>
        {issuedTickets.length === 0 ? (
          <p className="text-sm text-zinc-600 dark:text-zinc-400">
            No tickets have been issued for this event yet - tickets are created
            automatically once an order is paid.
          </p>
        ) : (
          <div className="overflow-x-auto rounded-lg border border-zinc-200 dark:border-zinc-800">
            <table className="w-full text-left text-sm">
              <thead className="bg-zinc-50 text-zinc-500 dark:bg-zinc-900 dark:text-zinc-400">
                <tr>
                  <th className="px-4 py-2 font-medium">Ticket</th>
                  <th className="px-4 py-2 font-medium">Type</th>
                  <th className="px-4 py-2 font-medium">Order</th>
                  <th className="px-4 py-2 font-medium">Status</th>
                  <th className="px-4 py-2 font-medium">Created at</th>
                </tr>
              </thead>
              <tbody>
                {issuedTickets.map((ticket) => (
                  <tr
                    key={ticket.id}
                    className="border-t border-zinc-200 dark:border-zinc-800"
                  >
                    <td className="px-4 py-2 text-zinc-900 dark:text-zinc-100">
                      {ticket.ticketNumber}
                    </td>
                    <td className="px-4 py-2 text-zinc-900 dark:text-zinc-100">
                      {ticketTypeNameById.get(ticket.ticketTypeId) ?? "—"}
                    </td>
                    {/* Truncated, debugging-only identifier - never a
                        buyer-facing or otherwise sensitive value. */}
                    <td className="px-4 py-2 font-mono text-xs text-zinc-500">
                      {ticket.orderId.slice(0, 8)}…
                    </td>
                    <td className="px-4 py-2 text-zinc-900 dark:text-zinc-100">
                      {ticket.status}
                    </td>
                    <td className="px-4 py-2 text-zinc-500">
                      {new Date(ticket.createdAt).toLocaleString()}
                    </td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        )}
      </section>
    </div>
  );
}
