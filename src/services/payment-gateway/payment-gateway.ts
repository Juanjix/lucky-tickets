import "server-only";

import type { Json } from "@/types/database";

/**
 * Provider-agnostic payment gateway abstraction (RFC-007 section 10).
 *
 * Nothing outside `src/services/payment-gateway/` and
 * `src/lib/mercado-pago/` may reference a Mercado Pago-specific type,
 * field name, or status string - every call site
 * (`src/features/payments/api.ts`, `src/features/payments/webhook.ts`)
 * talks only to this interface. `organizationId` is threaded through
 * `createCheckout` even though `MercadoPagoPaymentGateway` currently
 * ignores it (RFC-007 section 8: "keep the payment abstraction
 * organization-aware" while using a single server-side account for the
 * MVP) - a future RFC that resolves per-organizer credentials from
 * `payment_accounts` changes ONLY the gateway implementation, never any
 * caller.
 */

export type CheckoutLineItemInput = {
  /** Ticket type id - used as Mercado Pago's required per-item identifier (Items.id). Not a secret; purely a reconciliation aid. */
  id: string;
  title: string;
  quantity: number;
  /** Integer minor units - converted to the provider's expected major-unit representation entirely inside the gateway implementation. */
  unitPriceMinor: number;
};

export type CreateCheckoutInput = {
  organizationId: string;
  orderId: string;
  /** Always the Lucky Ticket order id, stringified - the provider correlation key (RFC-007 section 14). */
  externalReference: string;
  currency: string;
  items: CheckoutLineItemInput[];
  /** Omitted (undefined) when not available - Checkout Pro's payer.email is optional, and RFC-006's get_checkout_order boundary deliberately never returns buyer PII (see src/features/payments/api.ts). */
  buyerEmail: string | undefined;
  backUrls: {
    success: string;
    pending: string;
    failure: string;
  };
  notificationUrl: string;
  /** Non-secret reconciliation hints only - never a checkout token or PII beyond what section 15 allows. */
  metadata: Record<string, string>;
};

export type CheckoutPreference = {
  providerPreferenceId: string;
  checkoutUrl: string;
};

export type ProviderPayment = {
  providerPaymentId: string;
  /** The RAW provider status string (e.g. "approved") - mapping to Lucky Ticket's internal payment_status happens in src/lib/mercado-pago/mapper.ts, one layer up from this interface, never inside it. */
  status: string;
  /** Integer minor units - already converted from the provider's representation inside the gateway implementation (RFC-007 section 24). */
  transactionAmountMinor: number;
  currency: string;
  externalReference: string | null;
  paymentMethod: string | null;
  /** ISO 8601, or null if the provider has not approved this payment. */
  approvedAt: string | null;
  /** A safe, already-narrowed subset of the provider's raw response - never dumped wholesale (RFC-007 section 26). */
  safePayload: Json;
};

export interface PaymentGateway {
  createCheckout(input: CreateCheckoutInput): Promise<CheckoutPreference>;
  getPayment(providerPaymentId: string): Promise<ProviderPayment>;
}
