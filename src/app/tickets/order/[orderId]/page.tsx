import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { siteConfig } from "@/config/site";
import { getOrderTicketsForBuyer } from "@/features/tickets/queries";
import { TicketCard } from "@/features/tickets/components/ticket-card";

/**
 * The buyer-facing tickets page (RFC-008). Mobile-first: this is the page
 * a buyer opens on their phone at the venue door.
 *
 * Requires BOTH the `orderId` path segment and a `?token=` query param -
 * `getOrderTicketsForBuyer` enforces this (RFC-008: an order id alone is
 * never sufficient to read tickets, mirroring RFC-006's checkout-token
 * convention for `/checkout/[orderId]`). An invalid/missing token, a
 * nonexistent order, and an order that was never paid all render the SAME
 * `notFound()` - this route never confirms whether a given order id
 * exists to someone who doesn't hold a valid token for it.
 *
 * No authentication/login is required or checked here - the buyer never
 * created an account (RFC-006's whole premise); this route's
 * authorization is entirely the possession of the ticket-access token
 * handed out by `src/features/payments/queries.ts` once payment is
 * confirmed.
 */
export const metadata: Metadata = {
  title: siteConfig.name,
};

export default async function BuyerTicketsPage(
  props: PageProps<"/tickets/order/[orderId]">,
) {
  const { orderId } = await props.params;
  const searchParams = await props.searchParams;
  const tokenParam = searchParams.token;
  const token = typeof tokenParam === "string" ? tokenParam : undefined;

  const result = await getOrderTicketsForBuyer(orderId, token);

  if (!result) {
    notFound();
  }

  const eventDate = new Date(result.eventStartsAt).toLocaleString("es-AR", {
    dateStyle: "full",
    timeStyle: "short",
  });

  return (
    <div className="min-h-full bg-zinc-950 text-zinc-50">
      <div className="mx-auto flex w-full max-w-2xl flex-col gap-8 px-4 py-10 sm:px-6">
        <span className="text-xs font-semibold tracking-widest text-zinc-500 uppercase">
          {siteConfig.name}
        </span>

        <div className="flex flex-col gap-1 text-center">
          <h1 className="text-xl font-semibold tracking-tight text-zinc-50">
            {result.eventName}
          </h1>
          <p className="text-sm text-zinc-400">
            {eventDate}
            {result.eventVenueName ? ` · ${result.eventVenueName}` : ""}
          </p>
          <p className="text-xs text-zinc-500">{result.organizationName}</p>
        </div>

        <div className="flex flex-col gap-4">
          {result.tickets.map((ticket) => (
            <TicketCard key={ticket.ticketId} ticket={ticket} />
          ))}
        </div>

        <p className="text-center text-xs text-zinc-500">
          Guardá este enlace - podés volver a abrirlo cuando quieras para ver
          tus {result.tickets.length === 1 ? "entrada" : "entradas"}.
        </p>

        <footer className="border-t border-zinc-800 pt-6 text-center text-xs text-zinc-500">
          Ticketing seguro por {siteConfig.name}
        </footer>
      </div>
    </div>
  );
}
