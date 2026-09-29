import "server-only";

import { AppError } from "@/lib/errors/app-error";
import type { SupabaseServerClient } from "@/lib/supabase/server";
import { createServiceRoleClient } from "@/lib/supabase/service-role";
import { getTicketServerEnv } from "@/lib/env/server";
import { verifyTicketAccessToken } from "@/lib/tickets/access-token";
import { renderTicketQrDataUrl } from "@/lib/tickets/qr";

import type { BuyerOrderTickets } from "./types";

/**
 * The buyer-facing tickets read path (RFC-008).
 *
 * Mirrors `confirm_order_payment`'s own split-trust shape: the buyer's
 * capability token is verified HERE, in trusted server code, BEFORE the
 * database is ever touched - `get_order_tickets` (the RFC-008 migration)
 * is granted to `service_role` ONLY and re-verifies nothing about the
 * capability itself, exactly like `confirm_order_payment` never
 * re-verifies the Mercado Pago webhook signature (that also already
 * happened one layer up, in Node, before the RPC call). An order id
 * alone - even together with a well-formed-looking but wrong token - is
 * never sufficient: `verifyTicketAccessToken` uses a constant-time
 * comparison and short-circuits before any database call is made.
 *
 * Returns `null` for "not authorized to view this" (wrong/missing token,
 * nonexistent order, or an order that was never paid) - deliberately the
 * SAME outcome for all three, so the tickets page can render one generic
 * not-found state without letting a caller distinguish "wrong token" from
 * "no such order" (the same not-found-boundary convention RFC-006/007
 * already use for an invalid checkout token).
 *
 * Renders each ticket's QR as a data URL fresh on every call - nothing
 * about the raw token or the rendered image is cached, stored, or reused
 * across requests. This is precisely what makes "the buyer can reopen
 * their tickets page any time" work without ever having stored a raw QR
 * secret anywhere: it is decrypted on demand, used once to render an
 * image, and discarded when the request completes.
 */
export async function getOrderTicketsForBuyer(
  orderId: string,
  candidateAccessToken: string | null | undefined,
): Promise<BuyerOrderTickets | null> {
  if (!verifyTicketAccessToken(orderId, candidateAccessToken)) {
    return null;
  }

  const { QR_ENCRYPTION_KEY } = getTicketServerEnv();
  const supabase = createServiceRoleClient();

  const { data, error } = await supabase.rpc("get_order_tickets", {
    p_order_id: orderId,
    p_qr_encryption_key: QR_ENCRYPTION_KEY,
  });

  if (error) {
    // LT022 is get_order_tickets' own "not found or not paid" domain
    // error - a completely ordinary outcome (buyer somehow has a
    // capability token for an order that was never paid, or a stale
    // link), never an operational failure worth surfacing as a 500.
    if ((error as { code?: string }).code === "LT022") {
      return null;
    }

    throw new AppError("internal", "Failed to load tickets for this order.", {
      cause: error,
    });
  }

  const rows = data ?? [];
  if (rows.length === 0) {
    return null;
  }

  const first = rows[0];

  const tickets = await Promise.all(
    rows.map(async (row) => ({
      ticketId: row.ticket_id,
      ticketNumber: row.ticket_number,
      status: row.ticket_status,
      ticketTypeName: row.ticket_type_name,
      qrImageDataUrl: await renderTicketQrDataUrl(row.qr_raw_token),
      issuedAt: row.issued_at,
      checkedInAt: row.checked_in_at,
    })),
  );

  return {
    orderId,
    orderStatus: first.order_status,
    eventName: first.event_name,
    eventStartsAt: first.event_starts_at,
    eventVenueName: first.event_venue_name,
    organizationName: first.organization_name,
    tickets,
  };
}

export type EventTicketRow = {
  id: string;
  ticketNumber: string;
  ticketTypeId: string;
  orderId: string;
  status: string;
  createdAt: string;
};

/**
 * The admin "Issued Tickets" dashboard read (RFC-008). RLS-scoped
 * (`tickets_select_operator` - RFC-002, unchanged) plus an explicit
 * `organization_id`/`event_id` filter, same defense-in-depth convention
 * `src/features/events/queries.ts` already uses. Deliberately returns
 * only what a basic operational list needs - never the raw QR token,
 * the QR ciphertext, or any buyer-access/checkout secret. Ticket type
 * names are resolved by the caller (which already has the event's
 * ticket types loaded) rather than joined here, to avoid relying on
 * PostgREST's embedding behavior across this schema's composite foreign
 * keys for what is otherwise a small, simple list.
 */
export async function listEventTickets(
  supabase: SupabaseServerClient,
  organizationId: string,
  eventId: string,
): Promise<EventTicketRow[]> {
  const { data, error } = await supabase
    .from("tickets")
    .select("id, ticket_number, ticket_type_id, order_id, status, created_at")
    .eq("organization_id", organizationId)
    .eq("event_id", eventId)
    .order("created_at", { ascending: false });

  if (error) {
    throw new AppError("internal", "Failed to load issued tickets.", {
      cause: error,
    });
  }

  return (data ?? []).map((row) => ({
    id: row.id,
    ticketNumber: row.ticket_number,
    ticketTypeId: row.ticket_type_id,
    orderId: row.order_id,
    status: row.status,
    createdAt: row.created_at,
  }));
}
