import type { Metadata } from "next";
import { notFound } from "next/navigation";

import { siteConfig } from "@/config/site";
import { getPaymentStatus } from "@/features/payments/queries";
import { PaymentError } from "@/features/payments/errors";
import { PaymentStatusView } from "@/features/payments/components/payment-status-view";

/**
 * The single shared Mercado Pago return route (RFC-007 sections 16-18),
 * used for `back_urls.success`/`back_urls.pending`/`back_urls.failure`
 * alike - see `src/features/payments/api.ts`'s doc comment for why one
 * route is correct here: "Return routes are presentation-only" (section
 * 17), so behavior can never depend on which back_url Mercado Pago
 * actually redirected through, only on authoritative status queried here.
 *
 * Query params Mercado Pago appends (`payment_id`, `status`,
 * `collection_status`, `merchant_order_id`, ...) are intentionally NEVER
 * read by this page - RFC-007 sections 3/80: "Return-route query
 * parameters must not be authoritative." Only `orderId` and `token`
 * (Lucky Ticket's own params, round-tripped through `back_urls` - see
 * `src/features/payments/api.ts`) are used, and only to look up
 * authoritative state via `getPaymentStatus`.
 */
export const metadata: Metadata = {
  title: siteConfig.name,
};

export default async function PaymentResultPage(
  props: PageProps<"/payment/result">,
) {
  const searchParams = await props.searchParams;
  const orderIdParam = searchParams.orderId;
  const tokenParam = searchParams.token;

  const orderId = typeof orderIdParam === "string" ? orderIdParam : undefined;
  const token = typeof tokenParam === "string" ? tokenParam : undefined;

  if (!orderId) {
    notFound();
  }

  // Same structure as RFC-006's checkout page (src/app/checkout/[orderId]/page.tsx):
  // the try/catch is kept strictly around the data fetch, never around JSX
  // construction (react-hooks/error-boundaries - JSX built inside a
  // try/catch is not actually protected by it, since React renders
  // components later, not at JSX-construction time).
  let initial: Awaited<ReturnType<typeof getPaymentStatus>>;
  try {
    initial = await getPaymentStatus(orderId, token);
  } catch (error) {
    if (error instanceof PaymentError) {
      // Same uniform not-found boundary as RFC-006's checkout page - an
      // invalid/missing token must never distinguish "wrong token" from
      // "no such order" (RFC-006 section 33 precedent, reused here).
      notFound();
    }
    throw error;
  }

  return (
    <div className="min-h-full bg-zinc-950 text-zinc-50">
      <div className="mx-auto flex w-full max-w-2xl flex-col gap-8 px-4 py-10 sm:px-6">
        <span className="text-xs font-semibold tracking-widest text-zinc-500 uppercase">
          {siteConfig.name}
        </span>
        <PaymentStatusView
          orderId={orderId}
          checkoutToken={token ?? ""}
          initialStatus={initial.status}
        />
        <footer className="border-t border-zinc-800 pt-6 text-center text-xs text-zinc-500">
          Ticketing seguro por {siteConfig.name}
        </footer>
      </div>
    </div>
  );
}
