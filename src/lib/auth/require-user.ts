import "server-only";

import { redirect } from "next/navigation";

import { createClient } from "@/lib/supabase/server";

export type AuthenticatedUser = {
  id: string;
  email: string | null;
};

/**
 * Returns the current user's verified identity, or `null` if there is no
 * valid session.
 *
 * Uses `getClaims()` (the same method `src/lib/supabase/proxy.ts` already
 * uses for session refresh) rather than `getSession()`: `getClaims()`
 * verifies the JWT itself before trusting its contents, where a session
 * read from cookies alone must not be trusted for identity — see the
 * `@supabase/auth-js` documentation on `getUser()`/`getClaims()` vs
 * `getSession()`.
 *
 * Use this where the absence of a session is an expected, ordinary
 * outcome — e.g. `/login` deciding whether to redirect an already
 * signed-in visitor away — rather than an error. Use `requireUser()` below
 * for the common case where a session is mandatory.
 */
export async function getOptionalUser(): Promise<AuthenticatedUser | null> {
  const supabase = await createClient();
  const { data, error } = await supabase.auth.getClaims();

  if (error || !data?.claims) {
    return null;
  }

  return {
    id: data.claims.sub,
    email: typeof data.claims.email === "string" ? data.claims.email : null,
  };
}

/**
 * Requires a signed-in user for the rest of the current Server Component,
 * Server Action, or Route Handler. Redirects to `/login` (preserving
 * `next` as the post-login destination, read by `/login`'s page) when
 * there is none.
 *
 * This — not a cookie read, not a prop passed down from a layout, not
 * anything supplied by the client — is the one way application code
 * should establish "who is calling". See
 * `docs/rfcs/RFC-003-auth-organizations.md` "Authorization helpers".
 */
export async function requireUser(next?: string): Promise<AuthenticatedUser> {
  const user = await getOptionalUser();

  if (!user) {
    const suffix = next ? `?next=${encodeURIComponent(next)}` : "";
    redirect(`/login${suffix}`);
  }

  return user;
}
