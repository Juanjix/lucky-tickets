"use client";

import { useEffect, useRef, useState } from "react";

import type { PublicPaymentStatus } from "@/features/payments/types";

const STATUS_COPY: Record<
  PublicPaymentStatus,
  { title: string; body: string }
> = {
  PENDING_PAYMENT: {
    title: "Estamos verificando tu pago…",
    body: "Esto puede tardar unos segundos. No cierres esta página.",
  },
  PAID: {
    title: "Pago confirmado",
    body: "Tu compra se realizó con éxito. Vas a recibir la confirmación por email.",
  },
  PAYMENT_FAILED: {
    title: "No pudimos confirmar el pago",
    body: "Si el problema persiste, volvé al evento e intentá nuevamente.",
  },
  EXPIRED: {
    title: "La reserva venció",
    body: "El tiempo para completar el pago expiró. Volvé al evento y seleccioná tus entradas de nuevo.",
  },
};

/** Terminal states - polling stops here (RFC-007 section 46: "Stop polling when reaching a terminal state"). */
const TERMINAL_STATUSES: readonly PublicPaymentStatus[] = [
  "PAID",
  "PAYMENT_FAILED",
  "EXPIRED",
];

const POLL_INTERVAL_MS = 2000;
/** RFC-007 section 46: "Do not poll forever" - 60s of short-lived polling covers the realistic webhook-arrives-shortly-after-redirect window, not an unbounded wait. */
const MAX_POLL_ATTEMPTS = 30;

/**
 * Displays authoritative payment/order status and, while still
 * `PENDING_PAYMENT`, polls `GET /api/orders/[orderId]/payment-status`
 * every 2 seconds for up to 60 seconds (RFC-007 sections 17/46).
 *
 * This component NEVER trusts anything from the URL Mercado Pago
 * redirected through beyond `orderId`/`token` (RFC-007 sections 3/80) -
 * `initialStatus` and every subsequent poll result come only from Lucky
 * Ticket's own authoritative endpoint.
 */
export function PaymentStatusView({
  orderId,
  checkoutToken,
  initialStatus,
}: {
  orderId: string;
  checkoutToken: string;
  initialStatus: PublicPaymentStatus;
}) {
  const [status, setStatus] = useState<PublicPaymentStatus>(initialStatus);
  const [pollingStopped, setPollingStopped] = useState(false);
  const attemptsRef = useRef(0);

  useEffect(() => {
    if (TERMINAL_STATUSES.includes(initialStatus)) {
      return;
    }

    const intervalId = setInterval(async () => {
      attemptsRef.current += 1;

      try {
        const response = await fetch(
          `/api/orders/${orderId}/payment-status?token=${encodeURIComponent(checkoutToken)}`,
        );

        if (response.ok) {
          const body = (await response.json()) as {
            status: PublicPaymentStatus;
          };
          setStatus(body.status);

          if (TERMINAL_STATUSES.includes(body.status)) {
            clearInterval(intervalId);
          }
        }
      } catch {
        // A transient network error during one poll attempt is not fatal -
        // the next interval tick simply tries again. Only the attempt
        // ceiling below stops polling outright.
      }

      if (attemptsRef.current >= MAX_POLL_ATTEMPTS) {
        clearInterval(intervalId);
        setPollingStopped(true);
      }
    }, POLL_INTERVAL_MS);

    return () => clearInterval(intervalId);
    // eslint-disable-next-line react-hooks/exhaustive-deps -- orderId/checkoutToken/initialStatus are stable for this page's lifetime; re-running on `status` changes would restart the interval on every poll.
  }, []);

  const copy = STATUS_COPY[status];
  const isTerminal = TERMINAL_STATUSES.includes(status);

  return (
    <div className="flex flex-col gap-4 rounded-lg border border-zinc-800 p-6 text-center">
      <h1 className="text-xl font-semibold tracking-tight text-zinc-50">
        {copy.title}
      </h1>
      <p className="text-sm text-zinc-400">{copy.body}</p>
      {!isTerminal && pollingStopped ? (
        <p className="text-sm text-zinc-500">
          Todavía estamos esperando la confirmación. Podés actualizar esta
          página más tarde para ver el estado.
        </p>
      ) : null}
    </div>
  );
}
