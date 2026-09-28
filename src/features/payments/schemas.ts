import { z } from "zod";

/**
 * Validates `POST /api/payments/mercado-pago/preference`'s request body
 * (RFC-007 section 12). Deliberately absent, same as RFC-006's checkout
 * schema (src/features/checkout/schemas.ts): price, total, currency,
 * organizationId, eventId, orderStatus, paymentStatus - none of these are
 * buyer intent. The only inputs are the two things the buyer's browser
 * actually holds: which order, and proof of ownership (the raw checkout
 * token).
 */
export const createPreferenceRequestSchema = z.object({
  orderId: z.uuid("Invalid order id."),
  checkoutToken: z.string().trim().min(1, "Checkout token is required."),
});

export type CreatePreferenceRequestInput = z.infer<
  typeof createPreferenceRequestSchema
>;
