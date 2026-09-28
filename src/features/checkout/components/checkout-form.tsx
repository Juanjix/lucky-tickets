"use client";

import { zodResolver } from "@hookform/resolvers/zod";
import { useRouter } from "next/navigation";
import { useMemo, useState } from "react";
import { useForm } from "react-hook-form";

import { formatMoney } from "@/lib/money";
import { MAX_TICKETS_PER_ORDER } from "@/lib/checkout/constants";
import type { PublicTicketType } from "@/features/events/public/types";

import { checkoutBuyerSchema, type CheckoutBuyerInput } from "../schemas";
import type { CheckoutResponse } from "../types";

const AVAILABILITY_LABEL: Record<PublicTicketType["availability"], string> = {
  UPCOMING: "Sales start soon",
  AVAILABLE: "Available",
  SOLD_OUT: "Sold out",
  ENDED: "Sales ended",
};

function formatSalesStart(
  ticketType: PublicTicketType,
  timezone: string,
): string {
  if (!ticketType.salesStartAt) {
    return AVAILABILITY_LABEL.UPCOMING;
  }

  const date = new Intl.DateTimeFormat("es-AR", {
    timeZone: timezone,
    day: "numeric",
    month: "short",
  }).format(new Date(ticketType.salesStartAt));

  return `Sales start ${date}`;
}

const inputClassName =
  "rounded-md border border-zinc-700 bg-zinc-900 px-3 py-2 text-base text-zinc-50 outline-none focus:border-zinc-500";
const labelClassName = "text-sm font-medium text-zinc-100";
const errorClassName = "text-sm text-red-400";

/**
 * The buyer-facing ticket selection + checkout form (RFC-006 sections
 * 34-36), replacing RFC-005's static, disabled `TicketTypeList`.
 *
 * Selected quantities live ONLY in this component's React state - "NO
 * ORDER, NO HOLD" while the buyer is still adjusting quantities (RFC-006
 * section 35). Nothing is written to the database until "Continue to
 * checkout" is pressed. The subtotal shown while selecting is explicitly
 * labeled an ESTIMATE: it is computed from the same `priceMinor` values
 * the server already returned for display, but it is never what actually
 * gets charged - only `POST /api/checkout`'s response (the authoritative
 * `CheckoutResponse`) determines the real subtotal/total, and this
 * component never uses its own client-side sum for anything but display
 * (RFC-006 section 36: "client subtotal ≠ authoritative subtotal").
 */
export function CheckoutForm({
  organizationSlug,
  eventSlug,
  ticketTypes,
  timezone,
}: {
  organizationSlug: string;
  eventSlug: string;
  ticketTypes: PublicTicketType[];
  timezone: string;
}) {
  const router = useRouter();
  const [quantities, setQuantities] = useState<Record<string, number>>({});
  const [submitError, setSubmitError] = useState<string | null>(null);
  const [isSubmitting, setIsSubmitting] = useState(false);

  const {
    register,
    handleSubmit,
    formState: { errors },
  } = useForm<CheckoutBuyerInput>({
    resolver: zodResolver(checkoutBuyerSchema),
    defaultValues: { name: "", email: "" },
  });

  const totalQuantity = useMemo(
    () => Object.values(quantities).reduce((sum, qty) => sum + qty, 0),
    [quantities],
  );

  // Display-only. Never sent to the server, never used to decide whether
  // the checkout can proceed - see the component doc comment above.
  const estimatedSubtotalMinor = useMemo(
    () =>
      ticketTypes.reduce((sum, ticketType) => {
        const qty = quantities[ticketType.id] ?? 0;
        return sum + qty * ticketType.priceMinor;
      }, 0),
    [ticketTypes, quantities],
  );

  const currency = ticketTypes[0]?.currency;

  function setQuantity(ticketType: PublicTicketType, next: number) {
    const clamped = Math.max(
      0,
      Math.min(next, ticketType.maxPerOrder, MAX_TICKETS_PER_ORDER),
    );
    setQuantities((prev) => ({ ...prev, [ticketType.id]: clamped }));
  }

  const onSubmit = handleSubmit(async (buyer) => {
    setSubmitError(null);

    const items = ticketTypes
      .map((ticketType) => ({
        ticketTypeId: ticketType.id,
        quantity: quantities[ticketType.id] ?? 0,
      }))
      .filter((item) => item.quantity > 0);

    if (items.length === 0) {
      setSubmitError("Select at least one ticket.");
      return;
    }

    setIsSubmitting(true);
    try {
      const response = await fetch("/api/checkout", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({
          organizationSlug,
          eventSlug,
          items,
          buyer,
        }),
      });

      const body = await response.json();

      if (!response.ok) {
        setSubmitError(
          body?.error?.message ??
            "Something went wrong while processing your checkout.",
        );
        return;
      }

      const checkout = body as CheckoutResponse;
      router.push(
        `/checkout/${checkout.orderId}?token=${encodeURIComponent(checkout.checkoutToken)}`,
      );
    } catch {
      setSubmitError(
        "Could not reach the server. Check your connection and try again.",
      );
    } finally {
      setIsSubmitting(false);
    }
  });

  if (ticketTypes.length === 0) {
    return (
      <p className="text-sm text-zinc-400">
        Tickets for this event aren&apos;t available yet. Check back soon.
      </p>
    );
  }

  return (
    <form onSubmit={onSubmit} noValidate className="flex flex-col gap-6">
      <ul className="flex flex-col divide-y divide-zinc-800 rounded-lg border border-zinc-800">
        {ticketTypes.map((ticketType) => {
          const isSelectable = ticketType.availability === "AVAILABLE";
          const qty = quantities[ticketType.id] ?? 0;
          const statusLabel =
            ticketType.availability === "UPCOMING"
              ? formatSalesStart(ticketType, timezone)
              : AVAILABILITY_LABEL[ticketType.availability];

          return (
            <li
              key={ticketType.id}
              className="flex items-center justify-between gap-4 px-4 py-4"
            >
              <div className="flex flex-col gap-0.5">
                <span className="font-medium text-zinc-50">
                  {ticketType.name}
                </span>
                {ticketType.description ? (
                  <span className="text-sm text-zinc-400">
                    {ticketType.description}
                  </span>
                ) : null}
                <span className="text-sm font-medium text-zinc-50">
                  {formatMoney(ticketType.priceMinor, ticketType.currency)}
                </span>
                <span
                  className={
                    isSelectable
                      ? "text-sm text-emerald-400"
                      : "text-sm text-zinc-500"
                  }
                >
                  {statusLabel}
                </span>
                {qty > 0 ? (
                  <span className="text-sm text-zinc-400">
                    Subtotal:{" "}
                    {formatMoney(
                      qty * ticketType.priceMinor,
                      ticketType.currency,
                    )}
                  </span>
                ) : null}
              </div>

              {isSelectable ? (
                <div className="flex shrink-0 items-center gap-3">
                  <button
                    type="button"
                    onClick={() => setQuantity(ticketType, qty - 1)}
                    disabled={qty <= 0}
                    aria-label={`Decrease quantity for ${ticketType.name}`}
                    className="flex h-8 w-8 items-center justify-center rounded-md border border-zinc-700 text-zinc-50 disabled:opacity-40"
                  >
                    −
                  </button>
                  <span
                    className="w-4 text-center text-sm font-medium text-zinc-50"
                    aria-live="polite"
                  >
                    {qty}
                  </span>
                  <button
                    type="button"
                    onClick={() => setQuantity(ticketType, qty + 1)}
                    disabled={
                      qty >= ticketType.maxPerOrder ||
                      totalQuantity >= MAX_TICKETS_PER_ORDER
                    }
                    aria-label={`Increase quantity for ${ticketType.name}`}
                    className="flex h-8 w-8 items-center justify-center rounded-md border border-zinc-700 text-zinc-50 disabled:opacity-40"
                  >
                    +
                  </button>
                </div>
              ) : (
                <button
                  type="button"
                  disabled
                  aria-disabled="true"
                  className="shrink-0 rounded-md bg-zinc-50 px-4 py-2 text-sm font-medium text-zinc-950 opacity-40"
                >
                  Select
                </button>
              )}
            </li>
          );
        })}
      </ul>

      {totalQuantity > 0 ? (
        <div className="flex items-center justify-between rounded-lg border border-zinc-800 px-4 py-3">
          <span className="text-sm text-zinc-400">
            Estimated subtotal ({totalQuantity}{" "}
            {totalQuantity === 1 ? "ticket" : "tickets"})
          </span>
          <span className="text-base font-semibold text-zinc-50">
            {currency ? formatMoney(estimatedSubtotalMinor, currency) : null}
          </span>
        </div>
      ) : null}

      {totalQuantity > 0 ? (
        <div className="flex flex-col gap-4 rounded-lg border border-zinc-800 p-4">
          <h3 className="text-base font-semibold text-zinc-50">
            Your information
          </h3>

          <div className="flex flex-col gap-1.5">
            <label htmlFor="buyer-name" className={labelClassName}>
              Name
            </label>
            <input
              id="buyer-name"
              type="text"
              autoComplete="name"
              aria-invalid={errors.name ? "true" : "false"}
              className={inputClassName}
              {...register("name")}
            />
            {errors.name ? (
              <p role="alert" className={errorClassName}>
                {errors.name.message}
              </p>
            ) : null}
          </div>

          <div className="flex flex-col gap-1.5">
            <label htmlFor="buyer-email" className={labelClassName}>
              Email
            </label>
            <input
              id="buyer-email"
              type="email"
              autoComplete="email"
              aria-invalid={errors.email ? "true" : "false"}
              className={inputClassName}
              {...register("email")}
            />
            {errors.email ? (
              <p role="alert" className={errorClassName}>
                {errors.email.message}
              </p>
            ) : null}
          </div>

          {submitError ? (
            <p role="alert" className={errorClassName}>
              {submitError}
            </p>
          ) : null}

          <button
            type="submit"
            disabled={isSubmitting}
            className="rounded-md bg-zinc-50 px-4 py-2.5 text-sm font-medium text-zinc-950 disabled:opacity-60"
          >
            {isSubmitting ? "Processing…" : "Continue to checkout"}
          </button>
        </div>
      ) : null}
    </form>
  );
}
