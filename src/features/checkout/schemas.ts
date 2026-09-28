import { z } from "zod";

import {
  MAX_CHECKOUT_LINES,
  MAX_TICKETS_PER_ORDER,
} from "@/lib/checkout/constants";

/**
 * Validates the buyer-intent payload `POST /api/checkout` accepts (RFC-006
 * sections 15/16). This is a FIRST line of defense only - every check here
 * is re-implemented independently inside `create_order_with_hold` itself
 * (RFC-006 section 17: "Never rely solely on the public event page having
 * shown a ticket"), because a malicious caller can skip this schema
 * entirely and call the Postgres RPC directly with any anon credentials.
 * Rejecting obviously-malformed input here just avoids a wasted database
 * round trip and gives the browser a faster, clearer error.
 *
 * Deliberately absent from this schema (RFC-006 section 15): price,
 * subtotal, total, currency, organizationId, eventId, fee,
 * availableQuantity, expiresAt, orderStatus - none of these are buyer
 * intent, so none of them are accepted as input even if the UI happens to
 * display them. `.strict()` is not used here since Zod v4 objects already
 * strip unknown keys by default when read with `.parse`, but the object
 * shapes below simply never declare a field for any of those values, so
 * there is nothing for a malicious caller to smuggle through even if they
 * tried.
 */

const ticketTypeIdSchema = z.uuid("Invalid ticket type.");

const checkoutItemSchema = z.object({
  ticketTypeId: ticketTypeIdSchema,
  quantity: z
    .number()
    .int("Quantity must be a whole number.")
    .positive("Quantity must be at least 1.")
    // A generous per-line ceiling - the ticket type's own `max_per_order`
    // (unknown to this schema) and the cart-wide MAX_TICKETS_PER_ORDER
    // check below are what the database ultimately enforces; this just
    // rejects an obviously-absurd single-line quantity fast.
    .max(MAX_TICKETS_PER_ORDER, "Quantity exceeds the maximum per order."),
});

/** Exported separately so `CheckoutForm` can validate just the buyer fields client-side with the same rules the full request schema enforces. */
export const checkoutBuyerSchema = z.object({
  name: z
    .string()
    .trim()
    .min(1, "Enter your name.")
    .max(160, "Name must be 160 characters or fewer."),
  email: z
    .email("Enter a valid email address.")
    .trim()
    .toLowerCase()
    .max(254, "Email must be 254 characters or fewer."),
});

export const checkoutRequestSchema = z
  .object({
    organizationSlug: z.string().trim().min(1, "Organization is required."),
    eventSlug: z.string().trim().min(1, "Event is required."),
    items: z
      .array(checkoutItemSchema)
      .min(1, "Select at least one ticket.")
      .max(MAX_CHECKOUT_LINES, "Too many distinct ticket types selected."),
    buyer: checkoutBuyerSchema,
  })
  .superRefine((data, ctx) => {
    const seen = new Set<string>();
    for (const item of data.items) {
      if (seen.has(item.ticketTypeId)) {
        ctx.addIssue({
          code: z.ZodIssueCode.custom,
          message: "Duplicate ticket type in cart.",
          path: ["items"],
        });
        break;
      }
      seen.add(item.ticketTypeId);
    }

    const totalQuantity = data.items.reduce(
      (sum, item) => sum + item.quantity,
      0,
    );
    if (totalQuantity > MAX_TICKETS_PER_ORDER) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: `You can purchase at most ${MAX_TICKETS_PER_ORDER} tickets per order.`,
        path: ["items"],
      });
    }
  });

export type CheckoutRequestInput = z.infer<typeof checkoutRequestSchema>;
export type CheckoutBuyerInput = z.infer<typeof checkoutBuyerSchema>;
