import { formatMoney } from "@/lib/money";
import {
  formatEventDate,
  formatEventTime,
} from "@/features/events/public/format";
import type { CheckoutOrderView } from "@/features/checkout/types";
import { PaymentButton } from "@/features/payments/components/payment-button";

import { CheckoutCountdown } from "./checkout-countdown";

const STATUS_LABEL: Record<string, string> = {
  PENDING_PAYMENT: "Pending payment",
  EXPIRED: "Expired",
  PAID: "Paid",
  CANCELLED: "Cancelled",
  REFUNDED: "Refunded",
  PARTIALLY_REFUNDED: "Partially refunded",
  PAYMENT_FAILED: "Payment failed",
};

/**
 * The checkout continuation page's display (RFC-006 sections 39-41,
 * RFC-007 section 11). Purely presentational - every value here (status,
 * totals, expiration) came from `get_checkout_order`, never recomputed
 * client-side.
 *
 * The "Continuar al pago" CTA is now a real `PaymentButton` (RFC-007) -
 * only rendered while the order is still `PENDING_PAYMENT`, since
 * starting a Mercado Pago checkout for an already-PAID/EXPIRED/CANCELLED
 * order is never meaningful (the preference-creation endpoint would
 * reject it anyway - this is purely a "don't show a dead-end button" UX
 * choice, not a security boundary).
 */
export function CheckoutSummary({
  order,
  checkoutToken,
}: {
  order: CheckoutOrderView;
  checkoutToken: string;
}) {
  const isPending = order.orderStatus === "PENDING_PAYMENT";

  return (
    <div className="flex flex-col gap-6">
      <header className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold tracking-tight text-zinc-50">
          {order.event.name}
        </h1>
        <p className="text-sm text-zinc-400 capitalize">
          {formatEventDate(order.event.startsAt, order.organization.timezone)} ·{" "}
          {formatEventTime(order.event.startsAt, order.organization.timezone)}{" "}
          hs
        </p>
        {order.event.venueName ? (
          <p className="text-sm text-zinc-400">{order.event.venueName}</p>
        ) : null}
        <p className="text-sm text-zinc-500">
          Presentado por {order.organization.name}
        </p>
      </header>

      <div className="flex items-center justify-between rounded-lg border border-zinc-800 px-4 py-3">
        <span className="text-sm text-zinc-400">Estado de la orden</span>
        <span className="text-sm font-medium text-zinc-50">
          {STATUS_LABEL[order.orderStatus] ?? order.orderStatus}
        </span>
      </div>

      <CheckoutCountdown expiresAt={order.expiresAt} isPending={isPending} />

      <ul className="flex flex-col divide-y divide-zinc-800 rounded-lg border border-zinc-800">
        {order.items.map((item) => (
          <li
            key={item.ticketTypeId}
            className="flex items-center justify-between gap-4 px-4 py-4"
          >
            <div className="flex flex-col gap-0.5">
              <span className="font-medium text-zinc-50">{item.name}</span>
              <span className="text-sm text-zinc-400">
                {item.quantity} ×{" "}
                {formatMoney(item.unitPriceMinor, order.currency)}
              </span>
            </div>
            <span className="text-sm font-medium text-zinc-50">
              {formatMoney(item.lineTotalMinor, order.currency)}
            </span>
          </li>
        ))}
      </ul>

      <div className="flex flex-col gap-2 rounded-lg border border-zinc-800 px-4 py-3">
        <div className="flex items-center justify-between text-sm text-zinc-400">
          <span>Subtotal</span>
          <span>{formatMoney(order.subtotalMinor, order.currency)}</span>
        </div>
        <div className="flex items-center justify-between text-base font-semibold text-zinc-50">
          <span>Total</span>
          <span>{formatMoney(order.totalMinor, order.currency)}</span>
        </div>
      </div>

      {isPending ? (
        <PaymentButton orderId={order.orderId} checkoutToken={checkoutToken} />
      ) : null}
    </div>
  );
}
