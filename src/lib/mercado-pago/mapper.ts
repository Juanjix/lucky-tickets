import "server-only";

import type { Database } from "@/types/database";

type PaymentStatus = Database["public"]["Enums"]["payment_status"];

/**
 * Mercado Pago provider-status -> Lucky Ticket `payment_status` mapping
 * (RFC-007 section 38: "Create a clear mapping layer... do not spread
 * provider strings everywhere").
 *
 * Provider statuses per Mercado Pago's documented `GET /v1/payments/:id`
 * response (consulted directly for this RFC - see
 * docs/rfcs/RFC-007-mercado-pago-payments.md "Mercado Pago documentation"):
 * `approved`, `authorized`, `in_process`, `pending`, `rejected`,
 * `cancelled`, `refunded`, `charged_back`, `in_mediation`.
 *
 * Only `approved` ever allows a PENDING_PAYMENT -> PAID transition
 * (`confirm_order_payment` additionally re-validates amount/currency/state
 * regardless). Every other status is recorded faithfully in `payments`
 * for audit purposes but never moves the order.
 *
 * `refunded`/`charged_back`/`in_mediation` are intentionally simplified
 * (RFC-007 non-goals: refunds, chargebacks workflow) - see this module's
 * `REFUNDED`/`in_mediation` cases below and
 * docs/rfcs/RFC-007-mercado-pago-payments.md "Known limitations" for the
 * explicit statement of what is NOT reconciled by this RFC.
 */
const PROVIDER_STATUS_TO_PAYMENT_STATUS: Record<string, PaymentStatus> = {
  approved: "APPROVED",
  authorized: "PENDING",
  in_process: "PENDING",
  pending: "PENDING",
  rejected: "REJECTED",
  cancelled: "CANCELLED",
  refunded: "REFUNDED",
  // No CHARGED_BACK/IN_MEDIATION value exists in Lucky Ticket's
  // payment_status enum (RFC-002) - both are dispute states that RFC-007
  // explicitly does not implement resolution for (non-goals: chargebacks
  // workflow). Mapping them to REFUNDED is the closest honest analog
  // ("money is no longer settled with the platform") rather than
  // inventing a new enum value for a workflow this RFC does not act on.
  charged_back: "REFUNDED",
  in_mediation: "PENDING",
};

/** Maps a Mercado Pago provider status string to Lucky Ticket's internal `payment_status`. An unrecognized status maps to `PENDING` (never silently treated as APPROVED) so an unexpected/future provider status can never accidentally authorize a PAID transition. */
export function mapProviderStatusToPaymentStatus(
  providerStatus: string,
): PaymentStatus {
  return PROVIDER_STATUS_TO_PAYMENT_STATUS[providerStatus] ?? "PENDING";
}

/**
 * The float-major-units -> integer-minor-units conversion boundary
 * (RFC-007 section 24).
 *
 * Mercado Pago's `GET /v1/payments/:id` returns `transaction_amount` as a
 * JSON number in MAJOR currency units with up to 2 decimal places (e.g.
 * `10000` or `10000.5` for ARS $10,000.50) - confirmed directly against
 * Mercado Pago's documented payment resource shape, NOT assumed. Lucky
 * Ticket's authoritative money columns are integer minor units
 * (`src/lib/money.ts`), so this is the ONE place that conversion happens
 * for provider-reported amounts, mirroring `toMinorUnits` there but never
 * importing/reusing it directly - that helper is documented as being for
 * organizer-typed major-unit input, not provider API responses, and
 * keeping the two call sites textually separate makes it obvious neither
 * one silently started handling the other's input shape.
 *
 * `Number.prototype.toFixed(2)` first, THEN multiply by 100 and round:
 * this avoids the classic `10000.1 * 100 === 1000009.999999999` binary
 * floating-point artifact by snapping to at most 2 decimal digits before
 * the multiplication, rather than trusting the raw float's full
 * precision. Never compared as a float afterward - the result is always
 * an integer, compared with `===`/`<>` against another integer
 * (`confirm_order_payment`'s `p_paid_amount_minor <> v_order.total_amount`).
 */
export function providerAmountToMinorUnits(providerAmount: number): number {
  if (!Number.isFinite(providerAmount)) {
    throw new Error(
      `Mercado Pago reported a non-finite transaction_amount: ${providerAmount}`,
    );
  }

  const fixedMajorUnits = Number(providerAmount.toFixed(2));
  return Math.round(fixedMajorUnits * 100);
}
