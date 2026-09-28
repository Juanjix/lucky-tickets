"use client";

import { useRouter } from "next/navigation";
import { useEffect, useRef, useState } from "react";

/**
 * Presentation-only countdown (RFC-006 sections 41/42). Renders
 * "Tu reserva vence en 09:42" style text computed purely from the
 * AUTHORITATIVE `expiresAt` timestamp the server already returned
 * (`get_checkout_order`) - this component never decides anything about
 * inventory or order state; it only visualizes a timestamp.
 *
 * When the countdown reaches zero, it stops ticking and calls
 * `router.refresh()` once to re-run the Server Component
 * (`getCheckoutOrder`), so the page picks up whatever the database
 * authoritatively reports next (RFC-006 section 42: "the database
 * inventory must already treat hold as expired ... regardless of the
 * browser"). This component's own zero-reached state is never treated as
 * the source of truth - it just prompts a re-fetch of the real one.
 */
export function CheckoutCountdown({
  expiresAt,
  isPending,
}: {
  expiresAt: string;
  /** Whether the order is still reported as PENDING_PAYMENT by the server. If false (e.g. already EXPIRED), no countdown is shown at all. */
  isPending: boolean;
}) {
  const router = useRouter();
  const [remainingMs, setRemainingMs] = useState(
    () => new Date(expiresAt).getTime() - Date.now(),
  );
  // A ref, not state: this only guards against calling router.refresh()
  // more than once and is never used to drive rendering, so it must not
  // itself trigger a re-render (see the "set-state-in-effect" lint rule
  // this sidesteps).
  const hasRefreshedRef = useRef(false);

  useEffect(() => {
    if (!isPending) {
      return;
    }

    const tick = () => {
      const next = new Date(expiresAt).getTime() - Date.now();
      setRemainingMs(next);

      if (next <= 0 && !hasRefreshedRef.current) {
        hasRefreshedRef.current = true;
        router.refresh();
      }
    };

    tick();
    const interval = setInterval(tick, 1000);

    return () => clearInterval(interval);
  }, [expiresAt, isPending, router]);

  if (!isPending || remainingMs <= 0) {
    return (
      <p className="text-sm font-medium text-red-400">Tu reserva ha vencido.</p>
    );
  }

  const totalSeconds = Math.max(0, Math.floor(remainingMs / 1000));
  const minutes = String(Math.floor(totalSeconds / 60)).padStart(2, "0");
  const seconds = String(totalSeconds % 60).padStart(2, "0");

  return (
    <p className="text-sm font-medium text-amber-400">
      Tu reserva vence en {minutes}:{seconds}
    </p>
  );
}
