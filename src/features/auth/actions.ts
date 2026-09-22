"use server";

import { headers } from "next/headers";
import { redirect } from "next/navigation";

import { toPublicAuthError } from "@/lib/auth/auth-errors";
import { createClient } from "@/lib/supabase/server";
import { resolveLandingPath } from "@/features/organizations/server/resolve-landing-path";

import { signInSchema, signUpSchema } from "./schemas";

export type AuthActionResult =
  | { status: "error"; error: string }
  | { status: "redirect"; redirectTo: string }
  | { status: "check-email" };

/**
 * Best-effort absolute origin for this request, built from headers rather
 * than a hardcoded env var — there's no `NEXT_PUBLIC_SITE_URL` in this
 * project (see `.env.example`), and adding one solely for this would be
 * exactly the kind of extra abstraction RFC-003 says to avoid introducing
 * "just because this prompt mentions" a use for it. Used only to build the
 * email-confirmation redirect link below.
 */
async function getOrigin(): Promise<string> {
  const requestHeaders = await headers();
  const host =
    requestHeaders.get("x-forwarded-host") ?? requestHeaders.get("host");
  const protocol = requestHeaders.get("x-forwarded-proto") ?? "https";

  return `${protocol}://${host}`;
}

/**
 * Signs up a new user with email/password.
 *
 * Whether this returns an active session immediately or requires email
 * confirmation first depends on the Supabase project's own "Confirm
 * email" auth setting (a project-level configuration, not something this
 * codebase controls) — both outcomes are handled: `data.session` present
 * means the user is already signed in and can proceed straight to
 * onboarding; its absence means a confirmation email was sent, and
 * `/auth/confirm` (a Route Handler, see that file) is what completes sign-up
 * when the user clicks it.
 */
export async function signUpAction(input: unknown): Promise<AuthActionResult> {
  const parsed = signUpSchema.safeParse(input);

  if (!parsed.success) {
    return {
      status: "error",
      error: parsed.error.issues[0]?.message ?? "Invalid sign-up details.",
    };
  }

  const supabase = await createClient();
  const origin = await getOrigin();

  const { data, error } = await supabase.auth.signUp({
    email: parsed.data.email,
    password: parsed.data.password,
    options: {
      emailRedirectTo: `${origin}/auth/confirm?next=${encodeURIComponent("/onboarding")}`,
    },
  });

  if (error) {
    return { status: "error", error: toPublicAuthError(error) };
  }

  if (!data.session) {
    return { status: "check-email" };
  }

  return { status: "redirect", redirectTo: await resolveLandingPath(supabase) };
}

/** Signs in an existing user with email/password. */
export async function signInAction(input: unknown): Promise<AuthActionResult> {
  const parsed = signInSchema.safeParse(input);

  if (!parsed.success) {
    return {
      status: "error",
      error: parsed.error.issues[0]?.message ?? "Invalid sign-in details.",
    };
  }

  const supabase = await createClient();

  const { error } = await supabase.auth.signInWithPassword({
    email: parsed.data.email,
    password: parsed.data.password,
  });

  if (error) {
    return { status: "error", error: toPublicAuthError(error) };
  }

  return { status: "redirect", redirectTo: await resolveLandingPath(supabase) };
}

/**
 * Signs the current user out and redirects to `/login`. Meant to be bound
 * directly to a `<form action={signOutAction}>` (see
 * `src/features/auth/components/sign-out-button.tsx`) — a plain form
 * submission is the one case where calling `redirect()` from inside a
 * Server Action is unambiguously safe and doesn't need a client-side
 * `router.push` fallback, so this action, unlike `signInAction`/
 * `signUpAction` above, redirects itself rather than returning a result.
 */
export async function signOutAction(): Promise<void> {
  const supabase = await createClient();
  await supabase.auth.signOut();
  redirect("/login");
}
