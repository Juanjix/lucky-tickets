import type { BuyerTicket } from "../types";

const STATUS_LABEL: Record<string, string> = {
  VALID: "Válida",
  CHECKED_IN: "Ya escaneada",
  CANCELLED: "Cancelada",
  REFUNDED: "Reembolsada",
};

/**
 * One ticket, one QR - never a single shared QR for the whole order
 * (RFC-008: each ticket is an independent, individually-scannable
 * entity, since RFC-009 will check people in per-ticket). `ticket.qrImageDataUrl`
 * is a fresh, already-rendered PNG data URL - see
 * `src/features/tickets/queries.ts`; this component never sees or needs
 * the raw token itself.
 */
export function TicketCard({ ticket }: { ticket: BuyerTicket }) {
  const statusLabel = STATUS_LABEL[ticket.status] ?? ticket.status;
  const isValid = ticket.status === "VALID";

  return (
    <div className="flex flex-col items-center gap-4 rounded-lg border border-zinc-800 bg-zinc-900/50 p-6 text-center">
      <div className="flex flex-col gap-1">
        <span className="text-xs font-semibold tracking-widest text-zinc-500 uppercase">
          {ticket.ticketTypeName}
        </span>
        <span className="text-sm text-zinc-400">
          Entrada {ticket.ticketNumber}
        </span>
      </div>

      <div className="rounded-md bg-white p-3">
        {/* eslint-disable-next-line @next/next/no-img-element -- a data: URL cannot go through next/image's remote optimizer */}
        <img
          src={ticket.qrImageDataUrl}
          alt={`Código QR de la entrada ${ticket.ticketNumber}`}
          width={220}
          height={220}
          className="size-[220px]"
        />
      </div>

      <span
        className={
          isValid
            ? "rounded-full bg-emerald-500/10 px-3 py-1 text-xs font-semibold text-emerald-400"
            : "rounded-full bg-zinc-500/10 px-3 py-1 text-xs font-semibold text-zinc-400"
        }
      >
        {statusLabel}
      </span>
    </div>
  );
}
