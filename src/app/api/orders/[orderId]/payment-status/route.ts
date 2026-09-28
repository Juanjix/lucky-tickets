import { NextResponse } from "next/server";

import { getPaymentStatus } from "@/features/payments/queries";
import { PaymentError, toPaymentError } from "@/features/payments/errors";

/**
 * GET /api/orders/[orderId]/payment-status (RFC-007 section 45).
 *
 * Requires `?token=<rawCheckoutToken>` - the SAME secure checkout access
 * token RFC-006 introduced (RFC-007 section 45: "Order UUID alone must
 * not authorize access"). Returns only `{ orderId, status }` where status
 * is one of the four values RFC-007 section 18 defines - never a payment
 * record, never provider details. This is what
 * `src/app/payment/result/page.tsx`'s polling calls.
 */
export async function GET(
  request: Request,
  { params }: { params: Promise<{ orderId: string }> },
) {
  const { orderId } = await params;
  const url = new URL(request.url);
  const token = url.searchParams.get("token") ?? undefined;

  try {
    const result = await getPaymentStatus(orderId, token);
    return NextResponse.json(result, { status: 200 });
  } catch (rawError) {
    const error =
      rawError instanceof PaymentError ? rawError : toPaymentError(rawError);

    if (error.code === "UNKNOWN") {
      console.error(
        "[GET /api/orders/[orderId]/payment-status] unexpected failure",
        { cause: error.cause },
      );
    }

    return NextResponse.json(
      { error: { code: error.code, message: error.publicMessage } },
      { status: error.status },
    );
  }
}
