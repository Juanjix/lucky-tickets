import { NextResponse } from "next/server";

import { createCheckoutOrder } from "@/features/checkout/api";
import { CheckoutError, toCheckoutError } from "@/features/checkout/errors";
import { checkoutRequestSchema } from "@/features/checkout/schemas";

/**
 * POST /api/checkout (RFC-006 sections 30-33).
 *
 * This Route Handler is intentionally thin: parse JSON, validate shape
 * with Zod, generate the checkout token, and call the database - it
 * contains NO inventory/pricing/tenant logic of its own (RFC-006 section
 * 49: "Do not implement PostgreSQL-critical concurrency rules only in
 * JavaScript"). Every business invariant is re-verified inside
 * `create_order_with_hold`; this handler only translates between HTTP and
 * that RPC call.
 */
export async function POST(request: Request) {
  let body: unknown;
  try {
    body = await request.json();
  } catch {
    return NextResponse.json(
      { error: { code: "INVALID_QUANTITY", message: "Malformed JSON body." } },
      { status: 400 },
    );
  }

  const parsed = checkoutRequestSchema.safeParse(body);
  if (!parsed.success) {
    return NextResponse.json(
      {
        error: {
          code: "INVALID_QUANTITY",
          message: parsed.error.issues[0]?.message ?? "Invalid request.",
        },
      },
      { status: 400 },
    );
  }

  try {
    const result = await createCheckoutOrder(parsed.data);
    return NextResponse.json(result, { status: 201 });
  } catch (rawError) {
    const error =
      rawError instanceof CheckoutError ? rawError : toCheckoutError(rawError);

    if (error.code === "UNKNOWN") {
      // Never leak a raw Postgres/PostgREST error to the browser (RFC-006
      // section 32). Server-side logging only.
      console.error("[POST /api/checkout] unexpected checkout failure", {
        cause: error.cause,
      });
    }

    return NextResponse.json(
      { error: { code: error.code, message: error.publicMessage } },
      { status: error.status },
    );
  }
}
