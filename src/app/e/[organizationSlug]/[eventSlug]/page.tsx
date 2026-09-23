import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { siteConfig } from "@/config/site";
import {
  formatEventDate,
  formatEventTime,
} from "@/features/events/public/format";
import { getPublicEvent } from "@/features/events/public/queries";
import { TicketTypeList } from "@/features/events/public/components/ticket-type-list";

/**
 * The public, buyer-facing event page (RFC-005). No authentication is
 * required or checked anywhere on this route - `getPublicEvent` already
 * queries as `anon` regardless of who's browsing (see
 * src/lib/supabase/public.ts), so there is nothing here to gate.
 *
 * Metadata for a nonexistent/private event deliberately falls back to the
 * generic site title rather than describing the event that couldn't be
 * shown (RFC-005 "Metadata": "For nonexistent/private events, do not leak
 * metadata").
 */
export async function generateMetadata(
  props: PageProps<"/e/[organizationSlug]/[eventSlug]">,
): Promise<Metadata> {
  const { organizationSlug, eventSlug } = await props.params;
  const page = await getPublicEvent(organizationSlug, eventSlug);

  if (!page) {
    return { title: siteConfig.name };
  }

  const { event, organization } = page;

  return {
    title: `${event.name} · ${organization.name}`,
    description: event.description
      ? event.description.slice(0, 160)
      : `${event.name} — presented by ${organization.name}. Tickets via ${siteConfig.name}.`,
  };
}

export default async function PublicEventPage(
  props: PageProps<"/e/[organizationSlug]/[eventSlug]">,
) {
  const { organizationSlug, eventSlug } = await props.params;
  const page = await getPublicEvent(organizationSlug, eventSlug);

  if (!page) {
    notFound();
  }

  const { organization, event, ticketTypes } = page;

  return (
    <div className="min-h-full bg-zinc-950 text-zinc-50">
      <div className="mx-auto flex w-full max-w-2xl flex-col gap-8 px-4 py-10 sm:px-6">
        <header className="flex flex-col gap-1">
          <span className="text-xs font-semibold tracking-widest text-zinc-500 uppercase">
            {siteConfig.name}
          </span>
          <h1 className="text-2xl font-semibold tracking-tight text-balance sm:text-3xl">
            {event.name}
          </h1>
          <p className="text-sm text-zinc-400">
            Presentado por {organization.name}
          </p>
        </header>

        <section className="flex flex-col gap-1 text-sm text-zinc-300">
          <p className="text-base font-medium text-zinc-50 capitalize">
            {formatEventDate(event.startsAt, organization.timezone)}
          </p>
          <p>{formatEventTime(event.startsAt, organization.timezone)} hs</p>
          {event.venueName ? <p className="pt-2">{event.venueName}</p> : null}
          {event.venueAddress ? <p>{event.venueAddress}</p> : null}
        </section>

        {event.description ? (
          <section>
            <p className="text-sm leading-relaxed whitespace-pre-line text-zinc-300">
              {event.description}
            </p>
          </section>
        ) : null}

        <section className="flex flex-col gap-4">
          <h2 className="text-lg font-semibold tracking-tight">Entradas</h2>
          <TicketTypeList
            ticketTypes={ticketTypes}
            timezone={organization.timezone}
          />
        </section>

        <footer className="border-t border-zinc-800 pt-6 text-center text-xs text-zinc-500">
          Ticketing seguro por {siteConfig.name}
        </footer>
      </div>
    </div>
  );
}
