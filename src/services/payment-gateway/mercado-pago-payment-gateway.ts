import "server-only";

import { getPaymentServerEnv } from "@/lib/env/server";
import {
  createPaymentClient,
  createPreferenceClient,
} from "@/lib/mercado-pago/client";
import { providerAmountToMinorUnits } from "@/lib/mercado-pago/mapper";
import { fromMinorUnits } from "@/lib/money";

import type {
  CreateCheckoutInput,
  CheckoutPreference,
  PaymentGateway,
  ProviderPayment,
} from "./payment-gateway";

/**
 * Mercado Pago Checkout Pro implementation of `PaymentGateway`.
 *
 * This is the ONLY file (besides `src/lib/mercado-pago/*`) that imports
 * the `mercadopago` SDK or knows about Mercado Pago-specific field names
 * (`init_point`, `transaction_amount`, `external_reference`, ...).
 */
// Mercado Pago's own documentation explicitly warns against local
// domains in `back_urls` ("Do not use local domains in the back_urls
// value, such as 'localhost/' or '127.0.0.1'... We recommend using a
// server with a named domain (DNS)" -
// mercadopago.com/developers/en/docs/checkout-pro/checkout-customization/user-interface/redirection).
// In practice the preference-creation API only actively REJECTS this when
// `auto_return` is also set: it fails with an `invalid_auto_return`
// error whose message ("auto_return invalid. back_url.success must be
// defined") is misleading - `back_urls.success` IS defined, it's just a
// local address Mercado Pago won't auto-redirect to. `auto_return` is a
// pure UX nicety (it only saves the buyer one click - Mercado Pago's own
// "return to site" button on the pending/failure/approved receipt page
// still gets them back to `back_urls.success` either way), so rather than
// hard-failing every local `next dev` run that hasn't been put behind an
// HTTPS tunnel, this gateway only requests `auto_return` when the success
// URL is NOT a local address. This changes no security property: back_urls
// still derive exclusively from trusted server config (never request
// headers/browser input - RFC-007 section 48), and confirm_order_payment
// never trusts this URL for anything either way.
function isLocalUrl(url: string): boolean {
  try {
    const { hostname } = new URL(url);
    return (
      hostname === "localhost" ||
      hostname === "127.0.0.1" ||
      hostname === "::1" ||
      hostname === "0.0.0.0"
    );
  } catch {
    return false;
  }
}

export class MercadoPagoPaymentGateway implements PaymentGateway {
  async createCheckout(
    input: CreateCheckoutInput,
  ): Promise<CheckoutPreference> {
    // Idempotency key for preference CREATION (RFC-007 section 37):
    // Mercado Pago's SDK forwards `options.idempotencyKey` as the
    // standard idempotency header on the create call. Deriving it
    // deterministically from the order id means a retried request (e.g.
    // our own server retrying after a network timeout) can never mint a
    // second preference for the same order - Mercado Pago returns the
    // original response instead.
    const preferenceClient = createPreferenceClient(
      `lucky-ticket-preference:${input.orderId}`,
    );

    const response = await preferenceClient.create({
      body: {
        items: input.items.map((item) => ({
          id: item.id,
          title: item.title,
          quantity: item.quantity,
          currency_id: input.currency,
          unit_price: fromMinorUnits(item.unitPriceMinor),
        })),
        external_reference: input.externalReference,
        metadata: input.metadata,
        ...(input.buyerEmail ? { payer: { email: input.buyerEmail } } : {}),
        back_urls: {
          success: input.backUrls.success,
          pending: input.backUrls.pending,
          failure: input.backUrls.failure,
        },
        // Only meaningful for the "success" back_url - automatically
        // sends the buyer back to Lucky Ticket instead of showing
        // Mercado Pago's own "return to site" interstitial. Approved is
        // the only status this is safe for: Mercado Pago's own guidance
        // is that auto_return should not be relied on for pending/failure
        // paths, which this integration doesn't need it for anyway (RFC-007
        // section 17: those pages are presentation-only regardless).
        // Omitted entirely for a local (non-publicly-routable) success
        // URL - see isLocalUrl's comment above.
        ...(isLocalUrl(input.backUrls.success)
          ? {}
          : { auto_return: "approved" as const }),
        notification_url: input.notificationUrl,
      },
    });

    const providerPreferenceId = response.id;
    if (!providerPreferenceId) {
      throw new Error(
        "Mercado Pago did not return a preference id for a preference creation call.",
      );
    }

    const { MERCADO_PAGO_ACCESS_TOKEN } = getPaymentServerEnv();
    // Mercado Pago's own convention: test/sandbox application credentials
    // are prefixed "TEST-". Test credentials only ever produce a
    // meaningful sandbox_init_point (init_point still comes back but is
    // not usable for a real Checkout Pro test flow), so this picks the
    // URL that actually works for whichever credential is configured
    // rather than requiring a separate explicit "sandbox mode" flag.
    const isTestCredential = MERCADO_PAGO_ACCESS_TOKEN.startsWith("TEST-");
    const checkoutUrl = isTestCredential
      ? (response.sandbox_init_point ?? response.init_point)
      : (response.init_point ?? response.sandbox_init_point);

    if (!checkoutUrl) {
      throw new Error(
        "Mercado Pago did not return a checkout redirect URL for a preference creation call.",
      );
    }

    return { providerPreferenceId, checkoutUrl };
  }

  async getPayment(providerPaymentId: string): Promise<ProviderPayment> {
    const paymentClient = createPaymentClient();
    const payment = await paymentClient.get({ id: providerPaymentId });

    if (!payment.id || !payment.status || !payment.currency_id) {
      throw new Error(
        `Mercado Pago returned an incomplete payment resource for id ${providerPaymentId}.`,
      );
    }

    const transactionAmountMajor = payment.transaction_amount;
    if (typeof transactionAmountMajor !== "number") {
      throw new Error(
        `Mercado Pago payment ${providerPaymentId} has no numeric transaction_amount.`,
      );
    }

    return {
      providerPaymentId: String(payment.id),
      status: payment.status,
      transactionAmountMinor: providerAmountToMinorUnits(
        transactionAmountMajor,
      ),
      currency: payment.currency_id,
      externalReference: payment.external_reference ?? null,
      paymentMethod: payment.payment_method_id ?? null,
      approvedAt: payment.date_approved ?? null,
      // A deliberately narrow, safe subset (RFC-007 section 26: "Do not
      // dump the entire raw Mercado Pago payload into arbitrary public
      // JSON") - no payer PII beyond what Mercado Pago already required
      // us to collect, no card/authorization details.
      safePayload: {
        id: payment.id,
        status: payment.status,
        status_detail: payment.status_detail ?? null,
        payment_method_id: payment.payment_method_id ?? null,
        payment_type_id: payment.payment_type_id ?? null,
        transaction_amount: payment.transaction_amount,
        currency_id: payment.currency_id,
        external_reference: payment.external_reference ?? null,
        date_approved: payment.date_approved ?? null,
        date_created: payment.date_created ?? null,
      },
    };
  }
}
