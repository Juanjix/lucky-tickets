import "server-only";

import { MercadoPagoConfig, Payment, Preference } from "mercadopago";

import { getPaymentServerEnv } from "@/lib/env/server";

/**
 * Mercado Pago Node SDK initialization (RFC-007 section 49).
 *
 * Uses the official `mercadopago` npm package (github.com/mercadopago/sdk-nodejs),
 * actively maintained, Node >= 18 (this project runs Node 22 - RFC-007
 * section 49's compatibility check). A direct hand-rolled REST client was
 * considered and rejected: the SDK's `Preference`/`Payment` resource
 * clients are a thin, well-typed wrapper over exactly the two endpoints
 * RFC-007 needs (`POST /checkout/preferences`, `GET /v1/payments/:id`)
 * with no unused surface area, so there is no meaningful safety or
 * simplicity gained by bypassing it.
 *
 * `MERCADO_PAGO_ACCESS_TOKEN` (server-only, see src/lib/env/server.ts) is
 * read lazily, INSIDE this function, never at module load time - so
 * importing this module never requires the credential to be configured
 * (matters for `npm run build`, which evaluates modules without a real
 * `.env.local`).
 */
function createConfig(idempotencyKey?: string): MercadoPagoConfig {
  const { MERCADO_PAGO_ACCESS_TOKEN } = getPaymentServerEnv();

  return new MercadoPagoConfig({
    accessToken: MERCADO_PAGO_ACCESS_TOKEN,
    options: {
      timeout: 8000,
      ...(idempotencyKey ? { idempotencyKey } : {}),
    },
  });
}

/**
 * A `Preference` resource client, one per call (the SDK's client objects
 * are cheap and stateless beyond the config). `idempotencyKey` is passed
 * through to Mercado Pago on preference CREATION (RFC-007 section 37) - see
 * `src/services/payment-gateway/mercado-pago-payment-gateway.ts`, which
 * derives it deterministically from the order id so a retried request
 * (e.g. after a network timeout on our side) can never mint two
 * preferences for the same order.
 */
export function createPreferenceClient(idempotencyKey?: string): Preference {
  return new Preference(createConfig(idempotencyKey));
}

/** A `Payment` resource client for `GET /v1/payments/:id` (RFC-007 section 22) - the authoritative provider read. */
export function createPaymentClient(): Payment {
  return new Payment(createConfig());
}
