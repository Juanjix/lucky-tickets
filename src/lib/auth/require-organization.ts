import "server-only";

import { notFound, redirect } from "next/navigation";
import { cache } from "react";

import { AppError } from "@/lib/errors/app-error";
import { createClient } from "@/lib/supabase/server";
import type { Database, Tables } from "@/types/database";

import { requireUser, type AuthenticatedUser } from "./require-user";

export type OrganizationRole = Database["public"]["Enums"]["organization_role"];

export type OrganizationContext = {
  user: AuthenticatedUser;
  organization: Tables<"organizations">;
  membership: { role: OrganizationRole };
};

/**
 * Resolves `organizationSlug` (as it appears in `/dashboard/[organizationSlug]`
 * URLs) to an organization and verifies the current user belongs to it,
 * trusting nothing about organization membership from the client — only
 * the slug itself, taken from the URL.
 *
 * Routing decision: both "no organization has this slug" and "it exists,
 * but you're not a member of it" render as an ordinary 404
 * (`next/navigation`'s `notFound()`), not a 403. A 403 would itself leak
 * that the slug belongs to a real organization; RFC-002's RLS was
 * specifically designed so that a member of Organization A cannot observe
 * whether Organization B exists at all (see docs/database.md "Tenant
 * boundary") — collapsing both cases into the same 404 keeps that property
 * true at this layer too, not just at the database layer.
 *
 * An unauthenticated caller is handled separately, before either case:
 * they're redirected to `/login`, which reveals nothing about the slug
 * either (every dashboard URL redirects an unauthenticated visitor the
 * same way, whether or not the organization exists).
 *
 * RLS (`organizations_select_member`) is what actually makes the
 * organization row unreadable in the first place. The explicit membership
 * check below is a second, independent layer on top of that — the RFC's
 * "application authorization is an additional layer" requirement — not a
 * replacement for it: if a future change ever weakened the RLS policy,
 * this function would still refuse to proceed without a matching
 * `organization_members` row.
 *
 * Wrapped in React's `cache()` so a dashboard layout and the page it
 * renders can both call this for the same `organizationSlug` within one
 * request without doing the membership lookup twice — this is the
 * standard Next.js App Router per-request dedupe mechanism, not a
 * cross-request cache (a new request gets a fresh cache).
 */
export const requireOrganizationMembership = cache(
  async function requireOrganizationMembership(
    organizationSlug: string,
  ): Promise<OrganizationContext> {
    const user = await requireUser(`/dashboard/${organizationSlug}`);
    const supabase = await createClient();

    const { data: organization, error: organizationError } = await supabase
      .from("organizations")
      .select("*")
      .eq("slug", organizationSlug)
      .maybeSingle();

    if (organizationError) {
      throw new AppError("internal", "Failed to load organization.", {
        cause: organizationError,
      });
    }

    if (!organization) {
      notFound();
    }

    const { data: membership, error: membershipError } = await supabase
      .from("organization_members")
      .select("role")
      .eq("organization_id", organization.id)
      .eq("user_id", user.id)
      .maybeSingle();

    if (membershipError) {
      throw new AppError(
        "internal",
        "Failed to load organization membership.",
        {
          cause: membershipError,
        },
      );
    }

    if (!membership) {
      notFound();
    }

    return { user, organization, membership };
  },
);

/**
 * Same as `requireOrganizationMembership`, additionally requiring the
 * caller's role to be one of `allowedRoles`.
 *
 * Routing decision: unlike the membership check above, insufficient role
 * does not use `notFound()`. The caller already knows the organization
 * exists (they're a member of it) — hiding that would be pointless, not
 * protective — so this redirects back to the organization's own dashboard
 * home with a `?error=forbidden` flag the page reads to show a message,
 * rather than a bare 403 page. See
 * `docs/rfcs/RFC-003-auth-organizations.md` "Routing".
 *
 * Usage this RFC intentionally leaves for RFC-004 and later to actually
 * call with a real allow-list, e.g.:
 * `requireOrganizationRole(slug, ["OWNER", "ADMIN", "PRODUCER"])`.
 */
export async function requireOrganizationRole(
  organizationSlug: string,
  allowedRoles: readonly OrganizationRole[],
): Promise<OrganizationContext> {
  const context = await requireOrganizationMembership(organizationSlug);

  if (!allowedRoles.includes(context.membership.role)) {
    redirect(`/dashboard/${organizationSlug}?error=forbidden`);
  }

  return context;
}
