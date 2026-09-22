"use client";

import { zodResolver } from "@hookform/resolvers/zod";
import { useRouter } from "next/navigation";
import { useTransition } from "react";
import { useForm } from "react-hook-form";

import { createOrganizationAction } from "@/features/organizations/actions";
import {
  createOrganizationSchema,
  type CreateOrganizationInput,
} from "@/features/organizations/schemas";

export function CreateOrganizationForm() {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();

  const {
    register,
    handleSubmit,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<CreateOrganizationInput>({
    resolver: zodResolver(createOrganizationSchema),
    defaultValues: { name: "" },
  });

  const busy = isPending || isSubmitting;

  const onSubmit = handleSubmit((values) => {
    startTransition(async () => {
      const result = await createOrganizationAction(values);

      if (result.status === "error") {
        setError("root", { message: result.error });
        return;
      }

      router.push(result.redirectTo);
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
          Organization name
        </label>
        <input
          id="name"
          type="text"
          autoComplete="organization"
          placeholder="Los Pibes Producciones"
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
          Your dashboard URL is generated from this name. If it&apos;s already
          taken, we&apos;ll add a number to it.
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
        {busy ? "Creating…" : "Create organization"}
      </button>
    </form>
  );
}
