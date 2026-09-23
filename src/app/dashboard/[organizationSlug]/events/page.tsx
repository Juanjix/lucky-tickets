import Link from "next/link";

import { EVENT_MANAGER_ROLES } from "@/features/events/permissions";
import { listOrganizationEvents } from "@/features/events/queries";
import { requireOrganizationMembership } from "@/lib/auth/require-organization";
import { createClient } from "@/lib/supabase/server";

const STATUS_LABEL: Record<string, string> = {
  DRAFT: "Draft",
  PUBLISHED: "Published",
  FINISHED: "Finished",
  CANCELLED: "Cancelled",
  ARCHIVED: "Archived",
};

export default async function EventsPage(
  props: PageProps<"/dashboard/[organizationSlug]/events">,
) {
  const { organizationSlug } = await props.params;
  const { organization, membership } =
    await requireOrganizationMembership(organizationSlug);

  const supabase = await createClient();
  const events = await listOrganizationEvents(supabase, organization.id);

  const canCreate = (EVENT_MANAGER_ROLES as readonly string[]).includes(
    membership.role,
  );

  return (
    <div className="flex flex-col gap-6">
      <div className="flex flex-wrap items-center justify-between gap-3">
        <h1 className="text-xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
          Events
        </h1>
        {canCreate ? (
          <Link
            href={`/dashboard/${organizationSlug}/events/new`}
            className="rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-zinc-50 dark:bg-zinc-50 dark:text-zinc-950"
          >
            Create event
          </Link>
        ) : null}
      </div>

      {events.length === 0 ? (
        <div className="flex flex-col items-center gap-3 rounded-lg border border-dashed border-zinc-300 px-6 py-16 text-center dark:border-zinc-700">
          <p className="text-zinc-600 dark:text-zinc-400">
            No events yet.
            <br />
            Create your first event to start selling tickets.
          </p>
          {canCreate ? (
            <Link
              href={`/dashboard/${organizationSlug}/events/new`}
              className="rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-zinc-50 dark:bg-zinc-50 dark:text-zinc-950"
            >
              Create event
            </Link>
          ) : null}
        </div>
      ) : (
        <ul className="flex flex-col divide-y divide-zinc-200 rounded-lg border border-zinc-200 dark:divide-zinc-800 dark:border-zinc-800">
          {events.map((event) => (
            <li key={event.id}>
              <Link
                href={`/dashboard/${organizationSlug}/events/${event.id}`}
                className="flex flex-col gap-1 px-4 py-3 hover:bg-zinc-50 sm:flex-row sm:items-center sm:justify-between dark:hover:bg-zinc-900"
              >
                <div className="flex flex-col gap-0.5">
                  <span className="font-medium text-zinc-950 dark:text-zinc-50">
                    {event.name}
                  </span>
                  <span className="text-sm text-zinc-500 dark:text-zinc-400">
                    {new Date(event.starts_at).toLocaleString()}
                    {event.venue_name ? ` · ${event.venue_name}` : ""}
                  </span>
                </div>
                <span className="inline-flex w-fit items-center rounded-full border border-zinc-300 px-2.5 py-0.5 text-xs font-medium text-zinc-700 dark:border-zinc-700 dark:text-zinc-300">
                  {STATUS_LABEL[event.status] ?? event.status}
                </span>
              </Link>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
