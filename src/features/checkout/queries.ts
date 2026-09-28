import "server-only";

import { cache } from "react";

import { createPublicClient } from "@/lib/supabase/public";
import { hashCheckoutToken } from "@/lib/checkout/token";

import { CheckoutError, toCheckoutError } from "./errors";
import type { CheckoutLineItem, CheckoutOrderView } from "./types";

/**
 * Resolves the checkout continuation page's data via `get_checkout_order`
 * (RFC-006 sections 27/39). Requires BOTH `orderId` and the raw
 * `rawCheckoutToken` from the page's `?token=` query param - the order id
 * alone is never sufficient (RFC-006 section 23). The raw token is hashed
 * HERE, in trusted Node code, before ever reaching Postgres; only the hash
 * is sent over the wire to `get_checkout_order`.
 *
 * A missing/empty `rawCheckoutToken` is treated identically to an invalid
 * one (both raise `INVALID_CHECKOUT_TOKEN`) - callers should render the
 * exact same "invalid or expired checkout link" state for either.
 *
 * Wrapped in `cache()` for the same reason as
 * `src/features/events/public/queries.ts` - request-scoped memoization
 * only, so `generateMetadata` and the page component share one round trip.
 */
export const getCheckoutOrder = cache(async function getCheckoutOrder(
  orderId: string,
  rawCheckoutToken: string | undefined,
): Promise<CheckoutOrderView> {
  if (!rawCheckoutToken) {
    throw new CheckoutError("INVALID_CHECKOUT_TOKEN");
  }

  const supabase = createPublicClient();
  const tokenHash = hashCheckoutToken(rawCheckoutToken);

  const { data, error } = await supabase.rpc("get_checkout_order", {
    p_order_id: orderId,
    p_checkout_token_hash: tokenHash,
  });

  if (error) {
    throw toCheckoutError(error);
  }

  const row = data?.[0];
  if (!row) {
    throw new CheckoutError("INVALID_CHECKOUT_TOKEN");
  }

  const items = (row.items as unknown[]).map((rawItem): CheckoutLineItem => {
    const item = rawItem as {
      ticketTypeId: string;
      name: string;
      quantity: number;
      unitPriceAmount: number;
      lineTotalAmount: number;
    };

    return {
      ticketTypeId: item.ticketTypeId,
      name: item.name,
      quantity: item.quantity,
      unitPriceMinor: item.unitPriceAmount,
      lineTotalMinor: item.lineTotalAmount,
    };
  });

  return {
    orderId: row.order_id,
    orderStatus: row.order_status,
    expiresAt: row.expires_at,
    currency: row.currency,
    subtotalMinor: row.subtotal_amount,
    totalMinor: row.total_amount,
    event: {
      name: row.event_name,
      startsAt: row.event_starts_at,
      venueName: row.event_venue_name,
    },
    organization: {
      name: row.organization_name,
      timezone: row.organization_timezone,
    },
    items,
  };
});
