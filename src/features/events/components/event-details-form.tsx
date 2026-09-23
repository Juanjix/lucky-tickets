"use client";

import { zodResolver } from "@hookform/resolvers/zod";
import { useRouter } from "next/navigation";
import { useTransition } from "react";
import { useForm } from "react-hook-form";

import {
  fromDateTimeLocalValue,
  toDateTimeLocalValue,
} from "@/features/events/datetime";
import { updateEventAction } from "@/features/events/actions";
import type { EventRow } from "@/features/events/queries";
import {
  updateEventSchema,
  type UpdateEventInput,
} from "@/features/events/schemas";

type EventDetailsFormProps = {
  organizationSlug: string;
  event: EventRow;
};

const inputClassName =
  "rounded-md border border-zinc-300 px-3 py-2 text-base text-zinc-950 outline-none focus:border-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-50";
const labelClassName = "text-sm font-medium text-zinc-900 dark:text-zinc-100";
const errorClassName = "text-sm text-red-600 dark:text-red-400";

export function EventDetailsForm({
  organizationSlug,
  event,
}: EventDetailsFormProps) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();

  const {
    register,
    handleSubmit,
    setError,
    formState: { errors, isSubmitting, isSubmitSuccessful },
  } = useForm<UpdateEventInput>({
    resolver: zodResolver(updateEventSchema),
    defaultValues: {
      name: event.name,
      description: event.description ?? "",
      venueName: event.venue_name ?? "",
      venueAddress: event.venue_address ?? "",
      startsAt: toDateTimeLocalValue(event.starts_at),
      endsAt: toDateTimeLocalValue(event.ends_at),
      capacity: event.capacity != null ? String(event.capacity) : "",
    },
  });

  const busy = isPending || isSubmitting;

  const onSubmit = handleSubmit((values) => {
    startTransition(async () => {
      const result = await updateEventAction(organizationSlug, event.id, {
        ...values,
        startsAt: fromDateTimeLocalValue(values.startsAt),
        endsAt: values.endsAt
          ? fromDateTimeLocalValue(values.endsAt)
          : values.endsAt,
      });

      if (result.status === "error") {
        setError("root", { message: result.error });
        return;
      }

      router.refresh();
    });
  });

  return (
    <form onSubmit={onSubmit} noValidate className="flex flex-col gap-4">
      <div className="flex flex-col gap-1.5">
        <label htmlFor="name" className={labelClassName}>
          Event name
        </label>
        <input
          id="name"
          type="text"
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
        <label htmlFor="description" className={labelClassName}>
          Description
        </label>
        <textarea
          id="description"
          rows={3}
          aria-invalid={errors.description ? "true" : "false"}
          className={inputClassName}
          {...register("description")}
        />
        {errors.description ? (
          <p role="alert" className={errorClassName}>
            {errors.description.message}
          </p>
        ) : null}
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="venueName" className={labelClassName}>
            Venue name
          </label>
          <input
            id="venueName"
            type="text"
            aria-invalid={errors.venueName ? "true" : "false"}
            className={inputClassName}
            {...register("venueName")}
          />
          {errors.venueName ? (
            <p role="alert" className={errorClassName}>
              {errors.venueName.message}
            </p>
          ) : null}
        </div>

        <div className="flex flex-col gap-1.5">
          <label htmlFor="venueAddress" className={labelClassName}>
            Venue address
          </label>
          <input
            id="venueAddress"
            type="text"
            aria-invalid={errors.venueAddress ? "true" : "false"}
            className={inputClassName}
            {...register("venueAddress")}
          />
          {errors.venueAddress ? (
            <p role="alert" className={errorClassName}>
              {errors.venueAddress.message}
            </p>
          ) : null}
        </div>
      </div>

      <div className="grid gap-4 sm:grid-cols-2">
        <div className="flex flex-col gap-1.5">
          <label htmlFor="startsAt" className={labelClassName}>
            Starts at
          </label>
          <input
            id="startsAt"
            type="datetime-local"
            aria-invalid={errors.startsAt ? "true" : "false"}
            className={inputClassName}
            {...register("startsAt")}
          />
          {errors.startsAt ? (
            <p role="alert" className={errorClassName}>
              {errors.startsAt.message}
            </p>
          ) : null}
        </div>

        <div className="flex flex-col gap-1.5">
          <label htmlFor="endsAt" className={labelClassName}>
            Ends at (optional)
          </label>
          <input
            id="endsAt"
            type="datetime-local"
            aria-invalid={errors.endsAt ? "true" : "false"}
            className={inputClassName}
            {...register("endsAt")}
          />
          {errors.endsAt ? (
            <p role="alert" className={errorClassName}>
              {errors.endsAt.message}
            </p>
          ) : null}
        </div>
      </div>

      <div className="flex flex-col gap-1.5 sm:w-48">
        <label htmlFor="capacity" className={labelClassName}>
          Capacity (optional)
        </label>
        <input
          id="capacity"
          type="number"
          min={1}
          step={1}
          aria-invalid={errors.capacity ? "true" : "false"}
          className={inputClassName}
          {...register("capacity")}
        />
        {errors.capacity ? (
          <p role="alert" className={errorClassName}>
            {errors.capacity.message}
          </p>
        ) : null}
        <p className="text-sm text-zinc-500 dark:text-zinc-500">
          Leave blank if there&apos;s no overall attendance cap.
        </p>
      </div>

      {errors.root ? (
        <p role="alert" className={errorClassName}>
          {errors.root.message}
        </p>
      ) : null}

      {isSubmitSuccessful && !busy && !errors.root ? (
        <p
          role="status"
          className="text-sm text-emerald-600 dark:text-emerald-400"
        >
          Saved.
        </p>
      ) : null}

      <button
        type="submit"
        disabled={busy}
        className="w-fit rounded-md bg-zinc-950 px-4 py-2 text-base font-medium text-zinc-50 disabled:opacity-60 dark:bg-zinc-50 dark:text-zinc-950"
      >
        {busy ? "Saving…" : "Save changes"}
      </button>
    </form>
  );
}
