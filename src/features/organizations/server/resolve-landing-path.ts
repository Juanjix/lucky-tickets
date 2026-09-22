import "server-only";

import { AppError } from "@/lib/errors/app-error";
import type { SupabaseServerClient } from "@/lib/supabase/server";

/**
 * Where a signed-in user should land: their first organization's
 * dashboard, or `/onboarding` if they belong to none yet.
 *
 * "First" here means "the organization they joined first"
 * (`organization_members.created_at` ascending) — a deliberate,
 * deterministic choice distinct from `listMyOrganizations`, which orders
 * alphabetically for the switcher's UI. The RFC doesn't mandate a specific
 * definition of "first"; this one is stable across repeated logins rather
 * than depending on organization name.
 *
 * Used by: `/login` and `/signup` (redirecting an already-authenticated
 * visitor away), the post-sign-in/-sign-up Server Actions, `/dashboard`
 * (the slug-less index route), and `/onboarding` (redirecting a user who
 * already has an organization away from onboarding).
 */
export async function resolveLandingPath(
  supabase: SupabaseServerClient,
): Promise<string> {
  const { data, error } = await supabase
    .from("organization_members")
    .select("created_at, organizations(slug)")
    .order("created_at", { ascending: true })
    .limit(1)
    .maybeSingle();

  if (error) {
    throw new AppError(
      "internal",
      "Failed to resolve organization membership.",
      {
        cause: error,
      },
    );
  }

  if (!data?.organizations) {
    return "/onboarding";
  }

  return `/dashboard/${data.organizations.slug}`;
}
