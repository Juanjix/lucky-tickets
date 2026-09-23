import { formatMoney } from "@/lib/money";
import type { PublicTicketType } from "@/features/events/public/types";

const AVAILABILITY_LABEL: Record<PublicTicketType["availability"], string> = {
  UPCOMING: "Sales start soon",
  AVAILABLE: "Available",
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

/**
 * The buyer-facing ticket list. Purely presentational - the availability
 * label is already derived server-side (see
 * src/features/events/public/availability.ts) and passed in, so this
 * component makes no date/status decisions of its own.
 *
 * The "Select" action is deliberately NOT a working control (RFC-005:
 * "The [Select] interaction is NOT checkout yet... may be disabled/
 * non-functional"). It renders as a disabled button rather than a link or
 * a client-side handler, so there is nothing here for RFC-006 to have to
 * un-wire later - only to enable.
 */
export function TicketTypeList({
  ticketTypes,
  timezone,
}: {
  ticketTypes: PublicTicketType[];
  timezone: string;
}) {
  if (ticketTypes.length === 0) {
    return (
      <p className="text-sm text-zinc-400">
        Tickets for this event aren&apos;t available yet. Check back soon.
      </p>
    );
  }

  return (
    <ul className="flex flex-col divide-y divide-zinc-800 rounded-lg border border-zinc-800">
      {ticketTypes.map((ticketType) => {
        const isAvailable = ticketType.availability === "AVAILABLE";
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
                  isAvailable
                    ? "text-sm text-emerald-400"
                    : "text-sm text-zinc-500"
                }
              >
                {statusLabel}
              </span>
            </div>

            <button
              type="button"
              disabled
              aria-disabled="true"
              title="Ticket sales aren't open yet on Lucky Ticket."
              className="shrink-0 rounded-md bg-zinc-50 px-4 py-2 text-sm font-medium text-zinc-950 opacity-40"
            >
              Select
            </button>
          </li>
        );
      })}
    </ul>
  );
}
