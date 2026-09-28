import "server-only";

import { createPublicClient } from "@/lib/supabase/public";
import { generateCheckoutToken, hashCheckoutToken } from "@/lib/checkout/token";

import { toCheckoutError } from "./errors";
import type { CheckoutRequestInput } from "./schemas";
import type { CheckoutLineItem, CheckoutResponse } from "./types";

/**
 * Calls `create_order_with_hold` (RFC-006 section 22/30) via the SAME
 * anon-only client RFC-005's public read path uses
 * (`src/lib/supabase/public.ts`) - never a service-role client. RFC-006
 * section 74 explicitly lists "service-role checkout" as a non-goal: the
 * database enforces every invariant itself (the function is SECURITY
 * DEFINER precisely so it doesn't need elevated caller privileges), so
 * there is no reason for this Route Handler to hold broader database
 * credentials than any other anonymous visitor.
 *
 * The checkout token is generated and hashed HERE, in trusted Node code
 * (`src/lib/checkout/token.ts`), before the database is ever called -
 * only the hash is sent to Postgres. The raw token is threaded back out
 * through the return value so the Route Handler can put it in the
 * response exactly once; this function itself never logs it.
 */
export async function createCheckoutOrder(
  input: CheckoutRequestInput,
): Promise<CheckoutResponse> {
  const supabase = createPublicClient();

  const rawToken = generateCheckoutToken();
  const tokenHash = hashCheckoutToken(rawToken);

  const { data, error } = await supabase.rpc("create_order_with_hold", {
    p_organization_slug: input.organizationSlug,
    p_event_slug: input.eventSlug,
    p_items: input.items.map((item) => ({
      ticketTypeId: item.ticketTypeId,
      quantity: item.quantity,
    })),
    p_buyer_name: input.buyer.name,
    p_buyer_email: input.buyer.email,
    p_buyer_phone: null,
    p_checkout_token_hash: tokenHash,
  });

  if (error) {
    throw toCheckoutError(error);
  }

  const row = data?.[0];
  if (!row) {
    throw toCheckoutError(error);
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
    checkoutToken: rawToken,
    status: "PENDING_PAYMENT",
    expiresAt: row.expires_at,
    currency: row.currency,
    subtotalMinor: row.subtotal_amount,
    totalMinor: row.total_amount,
    items,
  };
}
