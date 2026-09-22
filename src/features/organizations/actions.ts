"use server";

import { requireUser } from "@/lib/auth/require-user";
import { slugify } from "@/lib/slug";
import { createClient } from "@/lib/supabase/server";

import { createOrganizationSchema } from "./schemas";

export type CreateOrganizationResult =
  | { status: "error"; error: string }
  | { status: "redirect"; redirectTo: string };

/**
 * Creates an organization and makes the calling user its OWNER, atomically,
 * via the `create_organization` database function (see the RFC-003
 * migration for why this must be a single RPC rather than two separate
 * inserts from here).
 *
 * The client only ever supplies a *name*. The slug is computed here, on
 * the server (`slugify`) — RFC-003 explicitly warns against relying on a
 * client-generated slug. Collisions are NOT resolved here: the database
 * function itself retries with a numeric suffix, because that's the only
 * place a collision can be detected and fixed atomically alongside the
 * insert that discovers it.
 */
export async function createOrganizationAction(
  input: unknown,
): Promise<CreateOrganizationResult> {
  // Authentication is required before we even attempt the RPC — this is
  // the application-layer check described in RFC-003's "Security rule".
  // The RPC's own RLS-backed authorization (see the migration) is the
  // real, final boundary and would refuse an unauthenticated call anyway;
  // this just produces a clean redirect instead of a raw RPC error.
  await requireUser("/onboarding");

  const parsed = createOrganizationSchema.safeParse(input);

  if (!parsed.success) {
    return {
      status: "error",
      error: parsed.error.issues[0]?.message ?? "Invalid organization name.",
    };
  }

  const slug = slugify(parsed.data.name);

  if (!slug) {
    return {
      status: "error",
      error:
        "That name doesn't produce a usable URL. Try including a letter or number.",
    };
  }

  const supabase = await createClient();

  const { data: organization, error } = await supabase.rpc(
    "create_organization",
    {
      p_name: parsed.data.name,
      p_slug: slug,
      p_timezone: "America/Argentina/Buenos_Aires",
    },
  );

  if (error || !organization) {
    return {
      status: "error",
      error: "Could not create the organization. Please try again.",
    };
  }

  return { status: "redirect", redirectTo: `/dashboard/${organization.slug}` };
}
