import { NextResponse } from "next/server";

import { createPaymentPreference } from "@/features/payments/api";
import { PaymentError, toPaymentError } from "@/features/payments/errors";
import { createPreferenceRequestSchema } from "@/features/payments/schemas";

/**
 * POST /api/payments/mercado-pago/preference (RFC-007 section 12).
 *
 * Input is ONLY `{ orderId, checkoutToken }` (RFC-007 section 12: "Never
 * accept price information from the browser"). Every authoritative value
 * (items, total, currency, back_urls, notification_url) is resolved
 * server-side from `get_checkout_order`/trusted config - see
 * `src/features/payments/api.ts`. This handler is intentionally thin,
 * same convention as `src/app/api/checkout/route.ts`.
 */
export async function POST(request: Request) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { error: { code: "UNKNOWN", message: "Malformed JSON body." } },
      { status: 400 },
    );
  }

  const parsed = createPreferenceRequestSchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json(
      {
        error: {
          code: "UNKNOWN",
          message: parsed.error.issues[0]?.message ?? "Invalid request.",
        },
      },
      { status: 400 },
    );
  }

  try {
    const result = await createPaymentPreference(
      parsed.data.orderId,
      parsed.data.checkoutToken,
    );
    return NextResponse.json(result, { status: 201 });
  } catch (rawError) {
    const error =
      rawError instanceof PaymentError ? rawError : toPaymentError(rawError);

    if (error.code === "UNKNOWN" || error.code === "PROVIDER_ERROR") {
      // Never leak a raw Postgres/Mercado Pago error to the browser.
      console.error(
        "[POST /api/payments/mercado-pago/preference] unexpected failure",
        { code: error.code, cause: error.cause },
      );
    }

    return NextResponse.json(
      { error: { code: error.code, message: error.publicMessage } },
      { status: error.status },
    );
  }
}
