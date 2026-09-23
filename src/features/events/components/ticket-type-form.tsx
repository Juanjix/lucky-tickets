"use client";

import { zodResolver } from "@hookform/resolvers/zod";
import { useTransition } from "react";
import { useForm } from "react-hook-form";

import {
  createTicketTypeAction,
  updateTicketTypeAction,
} from "@/features/events/actions";
import {
  fromDateTimeLocalValue,
  toDateTimeLocalValue,
} from "@/features/events/datetime";
import { fromMinorUnits } from "@/lib/money";
import type { TicketTypeRow } from "@/features/events/queries";
import {
  ticketVisibilities,
  createTicketTypeSchema,
  type CreateTicketTypeInput,
} from "@/features/events/schemas";

type TicketTypeFormProps = {
  organizationSlug: string;
  eventId: string;
  currency: string;
  /** When provided, the form edits this ticket type instead of creating a new one. */
  ticketType?: TicketTypeRow;
  onDone: () => void;
};

const inputClassName =
  "rounded-md border border-zinc-300 px-3 py-2 text-base text-zinc-950 outline-none focus:border-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-50";
const labelClassName = "text-sm font-medium text-zinc-900 dark:text-zinc-100";
const errorClassName = "text-sm text-red-600 dark:text-red-400";

export function TicketTypeForm({
  organizationSlug,
  eventId,
  currency,
  ticketType,
  onDone,
}: TicketTypeFormProps) {
  const [isPending, startTransition] = useTransition();
  const isEditing = Boolean(ticketType);

  const {
    register,
    handleSubmit,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<CreateTicketTypeInput>({
    resolver: zodResolver(createTicketTypeSchema),
    defaultValues: {
      name: ticketType?.name ?? "",
      description: ticketType?.description ?? "",
      priceMajor: ticketType
        ? String(fromMinorUnits(ticketType.unit_price_amount))
        : "",
      quantity: ticketType ? String(ticketType.quantity) : "1",
      visibility: ticketType?.visibility ?? "PUBLIC",
      salesStartAt: toDateTimeLocalValue(ticketType?.sales_start_at),
      salesEndAt: toDateTimeLocalValue(ticketType?.sales_end_at),
    },
  });

  const busy = isPending || isSubmitting;

  const onSubmit = handleSubmit((values) => {
    startTransition(async () => {
      const normalizedValues = {
        ...values,
        salesStartAt: values.salesStartAt
          ? fromDateTimeLocalValue(values.salesStartAt)
          : values.salesStartAt,
        salesEndAt: values.salesEndAt
          ? fromDateTimeLocalValue(values.salesEndAt)
          : values.salesEndAt,
      };

      const result = ticketType
        ? await updateTicketTypeAction(
            organizationSlug,
            ticketType.id,
            normalizedValues,
          )
        : await createTicketTypeAction(
            organizationSlug,
            eventId,
            normalizedValues,
          );

      if (result.status === "error") {
        setError("root", { message: result.error });
        return;
      }

      onDone();
    });
  });

  return (
    <form
      onSubmit={onSubmit}
      noValidate
      className="flex flex-col gap-4 rounded-lg border border-zinc-200 p-4 dark:border-zinc-800"
    >
      <div className="grid gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`name-${ticketType?.id ?? "new"}`}
            className={labelClassName}
          >
            Name
          </label>
          <input
            id={`name-${ticketType?.id ?? "new"}`}
            type="text"
            placeholder="General"
            aria-invalid={errors.name ? "true" : "false"}
            className={inputClassName}
            {...register("name")}
          />
          {errors.name ? (
            <p role="alert" className={errorClassName}>
              {errors.name.message}
            </p>
          ) : null}
        </div>

        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`visibility-${ticketType?.id ?? "new"}`}
            className={labelClassName}
          >
            Visibility
          </label>
          <select
            id={`visibility-${ticketType?.id ?? "new"}`}
            className={inputClassName}
            {...register("visibility")}
          >
            {ticketVisibilities.map((visibility) => (
              <option key={visibility} value={visibility}>
                {visibility === "PUBLIC" ? "Public" : "Hidden"}
              </option>
            ))}
          </select>
        </div>
      </div>

      <div className="flex flex-col gap-1.5">
        <label
          htmlFor={`description-${ticketType?.id ?? "new"}`}
          className={labelClassName}
        >
          Description (optional)
        </label>
        <input
          id={`description-${ticketType?.id ?? "new"}`}
          type="text"
          className={inputClassName}
          {...register("description")}
        />
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`priceMajor-${ticketType?.id ?? "new"}`}
            className={labelClassName}
          >
            Price ({currency})
          </label>
          <input
            id={`priceMajor-${ticketType?.id ?? "new"}`}
            type="number"
            min={0}
            step="0.01"
            aria-invalid={errors.priceMajor ? "true" : "false"}
            className={inputClassName}
            {...register("priceMajor")}
          />
          {errors.priceMajor ? (
            <p role="alert" className={errorClassName}>
              {errors.priceMajor.message}
            </p>
          ) : null}
        </div>

        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`quantity-${ticketType?.id ?? "new"}`}
            className={labelClassName}
          >
            Quantity
          </label>
          <input
            id={`quantity-${ticketType?.id ?? "new"}`}
            type="number"
            min={1}
            step={1}
            aria-invalid={errors.quantity ? "true" : "false"}
            className={inputClassName}
            {...register("quantity")}
          />
          {errors.quantity ? (
            <p role="alert" className={errorClassName}>
              {errors.quantity.message}
            </p>
          ) : null}
        </div>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`salesStartAt-${ticketType?.id ?? "new"}`}
            className={labelClassName}
          >
            Sales start (optional)
          </label>
          <input
            id={`salesStartAt-${ticketType?.id ?? "new"}`}
            type="datetime-local"
            className={inputClassName}
            {...register("salesStartAt")}
          />
        </div>

        <div className="flex flex-col gap-1.5">
          <label
            htmlFor={`salesEndAt-${ticketType?.id ?? "new"}`}
            className={labelClassName}
          >
            Sales end (optional)
          </label>
          <input
            id={`salesEndAt-${ticketType?.id ?? "new"}`}
            type="datetime-local"
            aria-invalid={errors.salesEndAt ? "true" : "false"}
            className={inputClassName}
            {...register("salesEndAt")}
          />
          {errors.salesEndAt ? (
            <p role="alert" className={errorClassName}>
              {errors.salesEndAt.message}
            </p>
          ) : null}
        </div>
      </div>

      {errors.root ? (
        <p role="alert" className={errorClassName}>
          {errors.root.message}
        </p>
      ) : null}

      <div className="flex gap-3">
        <button
          type="submit"
          disabled={busy}
          className="rounded-md bg-zinc-950 px-4 py-2 text-sm font-medium text-zinc-50 disabled:opacity-60 dark:bg-zinc-50 dark:text-zinc-950"
        >
          {busy
            ? "Saving…"
            : isEditing
              ? "Save ticket type"
              : "Add ticket type"}
        </button>
        <button
          type="button"
          onClick={onDone}
          disabled={busy}
          className="rounded-md border border-zinc-300 px-4 py-2 text-sm font-medium text-zinc-700 disabled:opacity-60 dark:border-zinc-700 dark:text-zinc-300"
        >
          Cancel
        </button>
      </div>
    </form>
  );
}
