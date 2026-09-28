import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { siteConfig } from "@/config/site";
import { CheckoutError } from "@/features/checkout/errors";
import { getCheckoutOrder } from "@/features/checkout/queries";
import { CheckoutSummary } from "@/features/checkout/components/checkout-summary";

/**
 * The checkout continuation page (RFC-006 sections 26/39). Requires BOTH
 * the `orderId` path segment and a `?token=` query param - `getCheckoutOrder`
 * enforces this (an order id alone is never sufficient, RFC-006 section
 * 23). An invalid, missing, or mismatched token renders the SAME
 * `notFound()` as a nonexistent order id, so this route never confirms
 * whether a given order id exists to someone who doesn't hold its token.
 *
 * No authentication is required or checked here - same design as
 * RFC-005's public event page: this route's authorization is entirely the
 * possession of the raw checkout token, not a login session.
 */
export const metadata: Metadata = {
  title: siteConfig.name,
};

export default async function CheckoutPage(
  props: PageProps<"/checkout/[orderId]">,
) {
  const { orderId } = await props.params;
  const searchParams = await props.searchParams;
  const tokenParam = searchParams.token;
  const token = typeof tokenParam === "string" ? tokenParam : undefined;

  let order: Awaited<ReturnType<typeof getCheckoutOrder>>;
  try {
    order = await getCheckoutOrder(orderId, token);
  } catch (error) {
    if (
      error instanceof CheckoutError &&
      error.code === "INVALID_CHECKOUT_TOKEN"
    ) {
      notFound();
    }
    throw error;
  }

  // getCheckoutOrder already required `token` to be a non-empty string to
  // reach this point (an undefined/empty token raises INVALID_CHECKOUT_TOKEN,
  // caught above) - this narrows it for CheckoutSummary/PaymentButton,
  // which need the raw token to authorize POST /api/payments/mercado-pago/preference
  // (RFC-007 section 11).
  const checkoutToken = token as string;

  return (
    <div className="min-h-full bg-zinc-950 text-zinc-50">
      <div className="mx-auto flex w-full max-w-2xl flex-col gap-8 px-4 py-10 sm:px-6">
        <span className="text-xs font-semibold tracking-widest text-zinc-500 uppercase">
          {siteConfig.name}
        </span>
        <CheckoutSummary order={order} checkoutToken={checkoutToken} />
        <footer className="border-t border-zinc-800 pt-6 text-center text-xs text-zinc-500">
          Ticketing seguro por {siteConfig.name}
        </footer>
      </div>
    </div>
  );
}
