import type { EventRow, TicketTypeRow } from "./queries";

/**
 * Centralized publication invariants (RFC-004 "Event publication") - the
 * single source of truth `publishEventAction` checks before ever
 * attempting the database update, kept here (not inlined in the action)
 * specifically so RFC-005/RFC-006 can import and reuse it rather than
 * re-implementing these rules. A deliberately minimal, matching backstop
 * also lives at the database layer (`enforce_event_publish_invariants()`
 * in the RFC-004 migration) - see that migration's comment for exactly
 * which two of these invariants are also enforced there, and why not all
 * of them need to be (several are already unconditionally guaranteed by
 * existing RFC-002 NOT NULL/CHECK constraints).
 *
 * Returns a list of human-readable reasons the event cannot currently be
 * published; an empty array means it can.
 */
export function getPublishIssues(
  event: Pick<EventRow, "name" | "starts_at" | "venue_name" | "capacity">,
  ticketTypes: readonly Pick<
    TicketTypeRow,
    "name" | "visibility" | "active" | "quantity" | "unit_price_amount"
  >[],
): string[] {
  const issues: string[] = [];

  if (!event.name || event.name.trim() === "") {
    issues.push("The event needs a name.");
  }

  if (!event.starts_at) {
    issues.push("The event needs a start date.");
  }

  if (!event.venue_name || event.venue_name.trim() === "") {
    issues.push("The event needs a venue.");
  }

  const sellable = ticketTypes.filter(
    (ticketType) => ticketType.visibility === "PUBLIC" && ticketType.active,
  );

  if (sellable.length === 0) {
    issues.push("At least one public ticket type is required to publish.");
  }

  for (const ticketType of sellable) {
    if (ticketType.unit_price_amount < 0) {
      issues.push(`"${ticketType.name}" has an invalid price.`);
    }

    if (ticketType.quantity <= 0) {
      issues.push(`"${ticketType.name}" has an invalid quantity.`);
    }
  }

  if (event.capacity != null) {
    const totalAllocated = ticketTypes
      .filter((ticketType) => ticketType.active)
      .reduce((sum, ticketType) => sum + ticketType.quantity, 0);

    if (totalAllocated > event.capacity) {
      issues.push("Configured ticket inventory exceeds the event's capacity.");
    }
  }

  return issues;
}
