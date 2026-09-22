"use client";

import { zodResolver } from "@hookform/resolvers/zod";
import Link from "next/link";
import { useRouter } from "next/navigation";
import { useTransition } from "react";
import { useForm } from "react-hook-form";

import { signInAction } from "@/features/auth/actions";
import { signInSchema, type SignInInput } from "@/features/auth/schemas";

type LoginFormProps = {
  /**
   * Where to send the user after a successful sign-in, if it's a safe
   * same-origin path (set by `requireUser()` when it redirected them here
   * from a protected page — see `/login`'s page.tsx). Falls back to the
   * server-computed landing path (first organization, or `/onboarding`)
   * when absent or unsafe.
   */
  nextPath?: string;
};

function isSafeRedirectPath(path: string | undefined): path is string {
  return (
    typeof path === "string" && path.startsWith("/") && !path.startsWith("//")
  );
}

export function LoginForm({ nextPath }: LoginFormProps) {
  const router = useRouter();
  const [isPending, startTransition] = useTransition();

  const {
    register,
    handleSubmit,
    setError,
    formState: { errors, isSubmitting },
  } = useForm<SignInInput>({
    resolver: zodResolver(signInSchema),
    defaultValues: { email: "", password: "" },
  });

  const busy = isPending || isSubmitting;

  const onSubmit = handleSubmit((values) => {
    startTransition(async () => {
      const result = await signInAction(values);

      if (result.status === "error") {
        setError("root", { message: result.error });
        return;
      }

      if (result.status === "redirect") {
        router.push(
          isSafeRedirectPath(nextPath) ? nextPath : result.redirectTo,
        );
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
          autoComplete="current-password"
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
        {busy ? "Signing in…" : "Sign in"}
      </button>

      <p className="text-sm text-zinc-600 dark:text-zinc-400">
        No account yet?{" "}
        <Link
          href="/signup"
          className="font-medium underline underline-offset-2"
        >
          Sign up
        </Link>
      </p>
    </form>
  );
}
