"use client";

import { zodResolver } from "@hookform/resolvers/zod";
import { useRouter } from "next/navigation";
import { useTransition } from "react";
import { useForm } from "react-hook-form";

import { createEventAction } from "@/features/events/actions";
import { fromDateTimeLocalValue } from "@/features/events/datetime";
import {
  createEventSchema,
  type CreateEventInput,
} from "@/features/events/schemas";

type CreateEventFormProps = {
  organizationSlug: string;
};

export function CreateEventForm({ organizationSlug }: CreateEventFormProps) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();

  const {
    register,
    handleSubmit,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<CreateEventInput>({
    resolver: zodResolver(createEventSchema),
    defaultValues: { name: "", startsAt: "" },
  });

  const busy = isPending || isSubmitting;

  const onSubmit = handleSubmit((values) => {
    startTransition(async () => {
      const result = await createEventAction(organizationSlug, {
        ...values,
        startsAt: fromDateTimeLocalValue(values.startsAt),
      });

      if (result.status === "error") {
        setError("root", { message: result.error });
        return;
      }

      if (result.status === "redirect") {
        router.push(result.redirectTo);
      }
    });
  });

  return (
    <form
      onSubmit={onSubmit}
      noValidate
      className="flex w-full max-w-sm flex-col gap-4"
    >
      <div className="flex flex-col gap-1.5">
        <label
          htmlFor="name"
          className="text-sm font-medium text-zinc-900 dark:text-zinc-100"
        >
          Event name
        </label>
        <input
          id="name"
          type="text"
          placeholder="The Strokes en Bahia Blanca"
          aria-invalid={errors.name ? "true" : "false"}
          aria-describedby={errors.name ? "name-error" : undefined}
          className="rounded-md border border-zinc-300 px-3 py-2 text-base text-zinc-950 outline-none focus:border-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-50"
          {...register("name")}
        />
        {errors.name ? (
          <p
            id="name-error"
            role="alert"
            className="text-sm text-red-600 dark:text-red-400"
          >
            {errors.name.message}
          </p>
        ) : null}
        <p className="text-sm text-zinc-500 dark:text-zinc-500">
          Its URL is generated from this name. If it&apos;s already taken within
          your organization, we&apos;ll add a number to it.
        </p>
      </div>

      <div className="flex flex-col gap-1.5">
        <label
          htmlFor="startsAt"
          className="text-sm font-medium text-zinc-900 dark:text-zinc-100"
        >
          Start date and time
        </label>
        <input
          id="startsAt"
          type="datetime-local"
          aria-invalid={errors.startsAt ? "true" : "false"}
          aria-describedby={errors.startsAt ? "startsAt-error" : undefined}
          className="rounded-md border border-zinc-300 px-3 py-2 text-base text-zinc-950 outline-none focus:border-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-50"
          {...register("startsAt")}
        />
        {errors.startsAt ? (
          <p
            id="startsAt-error"
            role="alert"
            className="text-sm text-red-600 dark:text-red-400"
          >
            {errors.startsAt.message}
          </p>
        ) : null}
        <p className="text-sm text-zinc-500 dark:text-zinc-500">
          Venue, description, capacity, and ticket types are all configured on
          the next screen - this is just enough to create the event as a draft.
        </p>
      </div>

      {errors.root ? (
        <p role="alert" className="text-sm text-red-600 dark:text-red-400">
          {errors.root.message}
        </p>
      ) : null}

      <button
        type="submit"
        disabled={busy}
        className="rounded-md bg-zinc-950 px-4 py-2 text-base font-medium text-zinc-50 disabled:opacity-60 dark:bg-zinc-50 dark:text-zinc-950"
      >
        {busy ? "Creating…" : "Create event"}
      </button>
    </form>
  );
}
