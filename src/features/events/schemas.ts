import { z } from "zod";

/**
 * Client-and-server-shared validation for events and ticket types. As with
 * `src/features/organizations/schemas.ts`, the database has the final say
 * (the CHECK constraints in the RFC-002 migration, plus the two new
 * capacity/publication triggers in the RFC-004 migration) - these schemas
 * exist to give the organizer fast, specific feedback, not to replace
 * those constraints.
 *
 * Every optional field below is a plain `z.string().optional()` with a
 * `.refine()`, deliberately NOT `z.preprocess()`: a preprocessed field's
 * *input* type (what `useForm()` below needs, since the form always holds
 * raw string values from HTML inputs) and its *output* type (what parsing
 * produces) diverge in a way `@hookform/resolvers` cannot cleanly bridge
 * for a field-by-field transform - a real issue hit while building this
 * form. Keeping input and output identical (`string | undefined`
 * throughout) sidesteps that entirely; each Server Action does the small
 * amount of "" -> null / string -> number conversion itself once the
 * shape is already validated - see src/features/events/actions.ts.
 */

function isValidDateString(value: string): boolean {
  return !Number.isNaN(Date.parse(value));
}

/** A `<input type="datetime-local">` value, required and non-empty. */
const requiredDateTime = z
  .string()
  .min(1, "Required.")
  .refine(isValidDateString, "Enter a valid date and time.");

/** Same shape, but an empty string (an untouched optional field) is accepted rather than rejected - "not provided" is a valid state, just not an invalid date. */
const optionalDateTime = z
  .string()
  .optional()
  .refine(
    (value) => !value || isValidDateString(value),
    "Enter a valid date and time.",
  );

const optionalText = (max: number) =>
  z
    .string()
    .optional()
    .refine(
      (value) => !value || value.trim().length <= max,
      `Must be ${max} characters or fewer.`,
    );

/** An `<input type="number">` value for event capacity: optional, and when provided must be a positive integer - mirrors `events_capacity_positive`. Stays a string here; `updateEventAction` converts it to a number. */
const optionalCapacity = z
  .string()
  .optional()
  .refine((value) => {
    if (!value) {
      return true;
    }

    const parsed = Number(value);
    return Number.isInteger(parsed) && parsed > 0;
  }, "Capacity must be a whole number greater than zero.");

export const createEventSchema = z.object({
  name: z
    .string()
    .trim()
    .min(2, "Event name must be at least 2 characters.")
    .max(160, "Event name must be 160 characters or fewer."),
  // Required at creation (the database's `starts_at` column is NOT NULL)
  // even though RFC-004 otherwise keeps creation minimal - venue,
  // description, capacity, and ticket types are all configured afterward.
  startsAt: requiredDateTime,
});

export type CreateEventInput = z.infer<typeof createEventSchema>;

export const updateEventSchema = z.object({
  name: z
    .string()
    .trim()
    .min(2, "Event name must be at least 2 characters.")
    .max(160, "Event name must be 160 characters or fewer."),
  description: optionalText(2000),
  venueName: optionalText(160),
  venueAddress: optionalText(240),
  startsAt: requiredDateTime,
  endsAt: optionalDateTime,
  capacity: optionalCapacity,
});

export type UpdateEventInput = z.infer<typeof updateEventSchema>;

export const ticketVisibilities = ["PUBLIC", "HIDDEN"] as const;

const ticketTypeFields = {
  name: z
    .string()
    .trim()
    .min(2, "Ticket type name must be at least 2 characters.")
    .max(120, "Ticket type name must be 120 characters or fewer."),
  description: optionalText(500),
  // A major-unit amount (e.g. 15000.5) as a string - converted to integer
  // minor units server-side via `toMinorUnits`, never stored as-is. See
  // src/lib/money.ts and src/features/events/actions.ts.
  priceMajor: z
    .string()
    .min(1, "Enter a price.")
    .refine((value) => {
      const parsed = Number(value);
      return Number.isFinite(parsed) && parsed >= 0;
    }, "Price cannot be negative."),
  quantity: z
    .string()
    .min(1, "Enter a quantity.")
    .refine((value) => {
      const parsed = Number(value);
      return Number.isInteger(parsed) && parsed > 0;
    }, "Quantity must be a whole number of at least 1."),
  visibility: z.enum(ticketVisibilities),
  salesStartAt: optionalDateTime,
  salesEndAt: optionalDateTime,
};

/**
 * Sales-window ordering is checked strictly (`>`) here, at the application
 * layer. RFC-002's own `ticket_types_sales_window_order` CHECK constraint
 * (unchanged - RFC-004 does not modify the RFC-002 migration) allows
 * `sales_start_at = sales_end_at`; this schema is intentionally the
 * stricter of the two, exactly as RFC-004 "Sales windows" specifies. The
 * database constraint still stands as a backstop for anything that
 * bypassed this form.
 */
const ticketTypeSalesWindowRefinement = <T extends z.ZodTypeAny>(schema: T) =>
  schema.superRefine((data, ctx) => {
    const { salesStartAt, salesEndAt } = data as {
      salesStartAt?: string;
      salesEndAt?: string;
    };

    if (
      salesStartAt &&
      salesEndAt &&
      new Date(salesEndAt) <= new Date(salesStartAt)
    ) {
      ctx.addIssue({
        code: z.ZodIssueCode.custom,
        message: "Sales end must be after sales start.",
        path: ["salesEndAt"],
      });
    }
  });

export const createTicketTypeSchema = ticketTypeSalesWindowRefinement(
  z.object(ticketTypeFields),
);

export type CreateTicketTypeInput = z.infer<typeof createTicketTypeSchema>;

export const updateTicketTypeSchema = ticketTypeSalesWindowRefinement(
  z.object(ticketTypeFields),
);

export type UpdateTicketTypeInput = z.infer<typeof updateTicketTypeSchema>;
