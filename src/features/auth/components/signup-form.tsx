"use client";

import { zodResolver } from "@hookform/resolvers/zod";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useState, useTransition } from "react";
import { useForm } from "react-hook-form";

import { signUpAction } from "@/features/auth/actions";
import { signUpSchema, type SignUpInput } from "@/features/auth/schemas";

export function SignupForm() {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();
  const [checkEmail, setCheckEmail] = useState(false);

  const {
    register,
    handleSubmit,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<SignUpInput>({
    resolver: zodResolver(signUpSchema),
    defaultValues: { email: "", password: "" },
  });

  const busy = isPending || isSubmitting;

  const onSubmit = handleSubmit((values) => {
    startTransition(async () => {
      const result = await signUpAction(values);

      if (result.status === "error") {
        setError("root", { message: result.error });
        return;
      }

      if (result.status === "check-email") {
        setCheckEmail(true);
        return;
      }

      router.push(result.redirectTo);
    });
  });

  if (checkEmail) {
    return (
      <div className="flex w-full max-w-sm flex-col gap-3" role="status">
        <p className="text-base text-zinc-900 dark:text-zinc-100">
          Check your email to confirm your account, then sign in.
        </p>
        <Link
          href="/login"
          className="text-sm font-medium underline underline-offset-2"
        >
          Back to sign in
        </Link>
      </div>
    );
  }

  return (
    <form
      onSubmit={onSubmit}
      noValidate
      className="flex w-full max-w-sm flex-col gap-4"
    >
      <div className="flex flex-col gap-1.5">
        <label
          htmlFor="email"
          className="text-sm font-medium text-zinc-900 dark:text-zinc-100"
        >
          Email
        </label>
        <input
          id="email"
          type="email"
          autoComplete="email"
          aria-invalid={errors.email ? "true" : "false"}
          aria-describedby={errors.email ? "email-error" : undefined}
          className="rounded-md border border-zinc-300 px-3 py-2 text-base text-zinc-950 outline-none focus:border-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-50"
          {...register("email")}
        />
        {errors.email ? (
          <p
            id="email-error"
            role="alert"
            className="text-sm text-red-600 dark:text-red-400"
          >
            {errors.email.message}
          </p>
        ) : null}
      </div>

      <div className="flex flex-col gap-1.5">
        <label
          htmlFor="password"
          className="text-sm font-medium text-zinc-900 dark:text-zinc-100"
        >
          Password
        </label>
        <input
          id="password"
          type="password"
          autoComplete="new-password"
          aria-invalid={errors.password ? "true" : "false"}
          aria-describedby={errors.password ? "password-error" : undefined}
          className="rounded-md border border-zinc-300 px-3 py-2 text-base text-zinc-950 outline-none focus:border-zinc-500 dark:border-zinc-700 dark:bg-zinc-900 dark:text-zinc-50"
          {...register("password")}
        />
        {errors.password ? (
          <p
            id="password-error"
            role="alert"
            className="text-sm text-red-600 dark:text-red-400"
          >
            {errors.password.message}
          </p>
        ) : null}
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
        {busy ? "Creating account…" : "Sign up"}
      </button>

      <p className="text-sm text-zinc-600 dark:text-zinc-400">
        Already have an account?{" "}
        <Link
          href="/login"
          className="font-medium underline underline-offset-2"
        >
          Sign in
        </Link>
      </p>
    </form>
  );
}
