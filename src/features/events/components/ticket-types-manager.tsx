"use client";

import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";

import { deleteTicketTypeAction } from "@/features/events/actions";
import { TicketTypeForm } from "@/features/events/components/ticket-type-form";
import type { TicketTypeRow } from "@/features/events/queries";
import { formatMoney } from "@/lib/money";

type TicketTypesManagerProps = {
  organizationSlug: string;
  eventId: string;
  currency: string;
  ticketTypes: TicketTypeRow[];
  /** Whether the current user holds an event-manager role - read-only otherwise, matching RFC-004 "Permissions": DOOR_STAFF/VIEWER see this list but no mutation controls. */
  canManage: boolean;
};

export function TicketTypesManager({
  organizationSlug,
  eventId,
  currency,
  ticketTypes,
  canManage,
}: TicketTypesManagerProps) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [editingId, setEditingId] = useState<string | "new" | null>(null);
  const [deleteError, setDeleteError] = useState<string | null>(null);

  function handleDone() {
    setEditingId(null);
    router.refresh();
  }

  function handleDelete(ticketTypeId: string, name: string) {
    if (!window.confirm(`Remove "${name}"? This can't be undone.`)) {
      return;
    }

    setDeleteError(null);

    startTransition(async () => {
      const result = await deleteTicketTypeAction(
        organizationSlug,
        ticketTypeId,
      );

      if (result.status === "error") {
        setDeleteError(result.error);
        return;
      }

      router.refresh();
    });
  }

  return (
    <div className="flex flex-col gap-4">
      {ticketTypes.length === 0 && editingId !== "new" ? (
        <p className="text-sm text-zinc-500 dark:text-zinc-500">
          No ticket types yet.
        </p>
      ) : null}

      <ul className="flex flex-col gap-3">
        {ticketTypes.map((ticketType) =>
          editingId === ticketType.id ? (
            <li key={ticketType.id}>
              <TicketTypeForm
                organizationSlug={organizationSlug}
                eventId={eventId}
                currency={currency}
                ticketType={ticketType}
                onDone={handleDone}
              />
            </li>
          ) : (
            <li
              key={ticketType.id}
              className="flex flex-col gap-1 rounded-lg border border-zinc-200 px-4 py-3 sm:flex-row sm:items-center sm:justify-between dark:border-zinc-800"
            >
              <div className="flex flex-col gap-0.5">
                <span className="font-medium text-zinc-950 dark:text-zinc-50">
                  {ticketType.name}
                  {ticketType.visibility === "HIDDEN" ? (
                    <span className="ml-2 rounded-full border border-zinc-300 px-2 py-0.5 text-xs font-normal text-zinc-500 dark:border-zinc-700 dark:text-zinc-400">
                      Hidden
                    </span>
                  ) : null}
                </span>
                <span className="text-sm text-zinc-500 dark:text-zinc-400">
                  {formatMoney(
                    ticketType.unit_price_amount,
                    ticketType.currency,
                  )}{" "}
                  · {ticketType.quantity} available
                </span>
              </div>
              {canManage ? (
                <div className="flex gap-3">
                  <button
                    type="button"
                    onClick={() => setEditingId(ticketType.id)}
                    className="text-sm font-medium text-zinc-700 underline-offset-2 hover:underline dark:text-zinc-300"
                  >
                    Edit
                  </button>
                  <button
                    type="button"
                    disabled={isPending}
                    onClick={() => handleDelete(ticketType.id, ticketType.name)}
                    className="text-sm font-medium text-red-600 underline-offset-2 hover:underline disabled:opacity-60 dark:text-red-400"
                  >
                    Remove
                  </button>
                </div>
              ) : null}
            </li>
          ),
        )}
      </ul>

      {deleteError ? (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {deleteError}
        </p>
      ) : null}

      {canManage ? (
        editingId === "new" ? (
          <TicketTypeForm
            organizationSlug={organizationSlug}
            eventId={eventId}
            currency={currency}
            onDone={handleDone}
          />
        ) : (
          <button
            type="button"
            onClick={() => setEditingId("new")}
            className="w-fit rounded-md border border-zinc-300 px-4 py-2 text-sm font-medium text-zinc-700 dark:border-zinc-700 dark:text-zinc-300"
          >
            Add ticket type
          </button>
        )
      ) : null}
    </div>
  );
}
