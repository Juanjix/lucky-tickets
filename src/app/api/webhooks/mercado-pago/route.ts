import { NextResponse } from "next/server";

import { processMercadoPagoWebhook } from "@/features/payments/webhook";

/**
 * POST /api/webhooks/mercado-pago (RFC-007 sections 19-23, 28-30, 43-44).
 *
 * This is the authoritative inbound provider boundary and Lucky Ticket's
 * ONLY consumer of the `service_role` Supabase credential (through
 * `src/features/payments/webhook.ts` -> `confirm_order_payment`). All
 * actual logic lives in `processMercadoPagoWebhook` - this handler only
 * extracts the transport-level inputs (headers, query params, raw body)
 * and maps its result to an HTTP response, so the orchestration itself
 * stays testable independently of the Next.js request/response types.
 *
 * The raw body text is read (not `request.json()`) because the webhook
 * signature's manifest, in principle, must be verified against exactly
 * the bytes Mercado Pago sent - re-serializing a parsed object could
 * differ byte-for-byte (key order, whitespace) even though Mercado Pago's
 * documented manifest only actually uses `data.id`/`x-request-id`/`ts`
 * (never a body hash), so this is a defensive convention rather than a
 * strict requirement of the current algorithm - see
 * src/lib/mercado-pago/signature.ts.
 */
export async function POST(request: Request) {
  const rawBody = await request.text();
  const url = new URL(request.url);

  const result = await processMercadoPagoWebhook({
    signatureHeader: request.headers.get("x-signature"),
    requestId: request.headers.get("x-request-id"),
    queryDataId: url.searchParams.get("data.id"),
    queryType: url.searchParams.get("type") ?? url.searchParams.get("topic"),
    rawBody,
  });

  return NextResponse.json(
    { status: result.reason },
    { status: result.httpStatus },
  );
}
