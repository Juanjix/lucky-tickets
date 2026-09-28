import "server-only";

import { createPublicClient } from "@/lib/supabase/public";
import { hashCheckoutToken } from "@/lib/checkout/token";
import { getPaymentServerEnv } from "@/lib/env/server";
import { MercadoPagoPaymentGateway } from "@/services/payment-gateway/mercado-pago-payment-gateway";
import type { PaymentGateway } from "@/services/payment-gateway/payment-gateway";

import { PaymentError, toPaymentError } from "./errors";
import type { CreatePreferenceResponse } from "./types";

/**
 * The single `PaymentGateway` instance this feature talks to. Swapping
 * providers later - or resolving a per-organization gateway from
 * `payment_accounts` (RFC-007 section 8's documented future step) -
 * changes only this one line, never any caller.
 */
function getPaymentGateway(): PaymentGateway {
  return new MercadoPagoPaymentGateway();
}

/**
 * Orchestrates `POST /api/payments/mercado-pago/preference` (RFC-007
 * section 12).
 *
 * 1. Verifies the checkout token AND loads the order's authoritative
 *    state via RFC-006's `get_checkout_order` (reused, not duplicated -
 *    RFC-007 section 4) - never trusts anything the browser sent beyond
 *    the order id + token.
 * 2. Rejects if the order isn't currently `PENDING_PAYMENT` (this also
 *    catches the virtually-EXPIRED case `get_checkout_order` itself
 *    derives - RFC-007 section 35).
 * 3. Reuses an existing Mercado Pago preference for this order if one was
 *    already created and the order is still payable (RFC-007 section 36:
 *    "prefer reusing an existing valid preference") - no second Mercado
 *    Pago API call, no second `record_payment_preference` write.
 * 4. Otherwise builds the preference from ONLY authoritative data
 *    (`get_checkout_order`'s own items/total/currency - never anything
 *    the browser posted) and persists the correlation via
 *    `record_payment_preference`.
 */
export async function createPaymentPreference(
  orderId: string,
  rawCheckoutToken: string,
): Promise<CreatePreferenceResponse> {
  const supabase = createPublicClient();
  const tokenHash = hashCheckoutToken(rawCheckoutToken);

  const { data, error } = await supabase.rpc("get_checkout_order", {
    p_order_id: orderId,
    p_checkout_token_hash: tokenHash,
  });

  if (error) {
    throw toPaymentError(error);
  }

  const row = data?.[0];
  if (!row) {
    throw new PaymentError("INVALID_CHECKOUT_TOKEN");
  }

  if (row.order_status !== "PENDING_PAYMENT") {
    throw new PaymentError("ORDER_NOT_PAYABLE");
  }

  if (row.provider_preference_id && row.provider_checkout_url) {
    return { checkoutUrl: row.provider_checkout_url };
  }

  const items = (row.items as unknown[]).map((rawItem) => {
    const item = rawItem as {
      ticketTypeId: string;
      name: string;
      quantity: number;
      unitPriceAmount: number;
    };
    return {
      // Mercado Pago's Items.id is a required per-item identifier; the
      // ticket type id is a safe, non-secret, already-authoritative value
      // to use for it (RFC-007 section: preference items must derive from
      // order_items/ticket_types, never the browser).
      id: item.ticketTypeId,
      title: item.name,
      quantity: item.quantity,
      unitPriceMinor: item.unitPriceAmount,
    };
  });

  const { NEXT_PUBLIC_APP_URL } = getPaymentServerEnv();
  // A single shared result route for success/pending/failure (RFC-007
  // section 17: "Return routes are presentation-only" - the page always
  // re-queries authoritative status regardless of which back_url Mercado
  // Pago actually redirected through, so three near-identical routes
  // would add nothing). The raw checkout token travels in this URL, which
  // Mercado Pago's servers do retain as part of the preference resource -
  // see docs/rfcs/RFC-007-mercado-pago-payments.md "Checkout token
  // preservation" for why this tradeoff was accepted for RFC-007's scope
  // rather than minting a separate payment-return token.
  const resultUrl = `${NEXT_PUBLIC_APP_URL}/payment/result?orderId=${encodeURIComponent(orderId)}&token=${encodeURIComponent(rawCheckoutToken)}`;

  const gateway = getPaymentGateway();

  let preference;
  try {
    preference = await gateway.createCheckout({
      organizationId: row.organization_id,
      orderId,
      externalReference: orderId,
      currency: row.currency,
      items,
      // Buyer email is not part of get_checkout_order's narrow return
      // (RFC-006 never exposes buyer PII back through this boundary);
      // Mercado Pago's payer.email is optional for Checkout Pro, so it is
      // safely omitted here rather than adding a new privileged read path
      // just to fetch it.
      buyerEmail: undefined,
      backUrls: {
        success: resultUrl,
        pending: resultUrl,
        failure: resultUrl,
      },
      notificationUrl: `${NEXT_PUBLIC_APP_URL}/api/webhooks/mercado-pago`,
      metadata: {
        order_id: orderId,
        organization_id: row.organization_id,
        event_name: row.event_name,
      },
    });
  } catch (cause) {
    throw new PaymentError("PROVIDER_ERROR", { cause });
  }

  const { error: persistError } = await supabase.rpc(
    "record_payment_preference",
    {
      p_order_id: orderId,
      p_checkout_token_hash: tokenHash,
      p_provider: "MERCADO_PAGO",
      p_provider_preference_id: preference.providerPreferenceId,
      p_provider_checkout_url: preference.checkoutUrl,
    },
  );

  if (persistError) {
    // The order became unpayable between our read above and this write
    // (e.g. it expired in that window) - the Mercado Pago preference we
    // just created becomes an orphan (harmless: confirm_order_payment
    // independently re-verifies order state/inventory before ever
    // honoring a payment against it - see the migration's payment-truth
    // boundary). Surface the real reason to the buyer rather than a
    // generic failure.
    throw toPaymentError(persistError);
  }

  return { checkoutUrl: preference.checkoutUrl };
}
