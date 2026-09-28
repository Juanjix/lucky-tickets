import "server-only";

import { createPublicClient } from "@/lib/supabase/public";
import { hashCheckoutToken } from "@/lib/checkout/token";

import { PaymentError, toPaymentError } from "./errors";
import type { PaymentStatusResponse, PublicPaymentStatus } from "./types";

/**
 * Folds `get_checkout_order`'s full `order_status` (RFC-006's enum, plus
 * its own virtual `EXPIRED` derivation) down to the 4-value status RFC-007
 * section 45's payment-status endpoint returns. `CANCELLED` and the two
 * refund states are folded into `PAYMENT_FAILED`/`PAID` respectively
 * (never a 5th value the result page - src/app/payment/result - wasn't
 * built to handle):
 *
 *   - `PENDING_PAYMENT` -> `PENDING_PAYMENT` (verbatim)
 *   - `PAID` -> `PAID` (verbatim)
 *   - `EXPIRED` -> `EXPIRED` (verbatim, already timestamp-aware from
 *     `get_checkout_order` itself)
 *   - `PAYMENT_FAILED`, `CANCELLED` -> `PAYMENT_FAILED` (both mean "this
 *     specific attempt/order did not result in a completed purchase")
 *   - `REFUNDED`, `PARTIALLY_REFUNDED` -> `PAID` (the purchase itself DID
 *     succeed - showing "we couldn't confirm your payment" here would be
 *     actively wrong; refund-specific messaging is a future RFC's concern,
 *     not RFC-007's)
 */
function foldOrderStatus(orderStatus: string): PublicPaymentStatus {
  switch (orderStatus) {
    case "PENDING_PAYMENT":
      return "PENDING_PAYMENT";
    case "PAID":
    case "REFUNDED":
    case "PARTIALLY_REFUNDED":
      return "PAID";
    case "EXPIRED":
      return "EXPIRED";
    case "PAYMENT_FAILED":
    case "CANCELLED":
    default:
      return "PAYMENT_FAILED";
  }
}

/**
 * `GET /api/orders/[orderId]/payment-status` (RFC-007 section 45).
 * Reuses `get_checkout_order` (RFC-006) rather than a new RPC - the same
 * order id + checkout token hash authorization boundary applies
 * identically here, and RFC-007 section 4 asks to reuse existing RFC-006
 * infrastructure wherever it already fits. An order id alone is never
 * sufficient (same as every other checkout/payment read path in this
 * codebase).
 */
export async function getPaymentStatus(
  orderId: string,
  rawCheckoutToken: string | undefined,
): Promise<PaymentStatusResponse> {
  if (!rawCheckoutToken) {
    throw new PaymentError("INVALID_CHECKOUT_TOKEN");
  }

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

  return {
    orderId: row.order_id,
    status: foldOrderStatus(row.order_status),
  };
}
