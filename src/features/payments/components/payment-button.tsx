"use client";

import { useState } from "react";

/**
 * "Continuar al pago" (RFC-007 section 11), replacing RFC-006's
 * permanently-disabled placeholder button in
 * `src/features/checkout/components/checkout-summary.tsx`.
 *
 * Sends ONLY `{ orderId, checkoutToken }` to
 * `POST /api/payments/mercado-pago/preference` (RFC-007 section 12: the
 * browser never sends price/total/currency/order status). On success,
 * navigates the buyer's own browser to Mercado Pago's hosted Checkout Pro
 * page (`window.location.href = checkoutUrl`) - a real cross-origin
 * navigation, not a fetch-and-render, since Checkout Pro is explicitly
 * NOT embedded (RFC-007 section 6: "Do not build a custom card form").
 */
export function PaymentButton({
  orderId,
  checkoutToken,
}: {
  orderId: string;
  checkoutToken: string;
}) {
  const [isSubmitting, setIsSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleClick() {
    if (isSubmitting) {
      return;
    }

    setError(null);
    setIsSubmitting(true);

    try {
      const response = await fetch("/api/payments/mercado-pago/preference", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ orderId, checkoutToken }),
      });

      const body = await response.json();

      if (!response.ok) {
        setError(
          body?.error?.message ??
            "No pudimos iniciar el pago. Intentá de nuevo.",
        );
        setIsSubmitting(false);
        return;
      }

      window.location.href = body.checkoutUrl as string;
      // Deliberately leave isSubmitting=true - the button should stay
      // disabled/loading through the outgoing navigation rather than
      // flicker back to enabled right before the browser leaves the page.
    } catch {
      setError("No pudimos conectar con el servidor. Probá de nuevo.");
      setIsSubmitting(false);
    }
  }

  return (
    <div className="flex flex-col gap-2">
      <button
        type="button"
        onClick={handleClick}
        disabled={isSubmitting}
        className="rounded-md bg-zinc-50 px-4 py-2.5 text-sm font-medium text-zinc-950 disabled:opacity-60"
      >
        {isSubmitting ? "Redirigiendo a Mercado Pago…" : "Continuar al pago"}
      </button>
      {error ? (
        <p role="alert" className="text-sm text-red-400">
          {error}
        </p>
      ) : null}
    </div>
  );
}
