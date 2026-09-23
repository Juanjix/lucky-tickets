import Link from "next/link";

import { SignOutButton } from "@/features/auth/components/sign-out-button";
import { OrganizationSwitcher } from "@/features/organizations/components/organization-switcher";
import { listMyOrganizations } from "@/features/organizations/server/list-my-organizations";
import { requireOrganizationMembership } from "@/lib/auth/require-organization";
import { createClient } from "@/lib/supabase/server";

/**
 * Every route under /dashboard/[organizationSlug] shares this layout, so
 * the membership check happens exactly once per request here rather than
 * being repeated (or, worse, forgotten) in each page. Child pages needing
 * the caller's role for their own authorization should still call
 * `requireOrganizationRole` themselves - this layout only establishes
 * membership, the minimum every dashboard route needs.
 *
 * RFC-004 adds the minimum navigation it needs (Dashboard, Events) to this
 * same header - deliberately not a redesign; a real navigation component
 * (active-state styling, more sections, mobile menu) is left to whichever
 * RFC first needs more than two links.
 */
export default async function OrganizationDashboardLayout(
  props: LayoutProps<"/dashboard/[organizationSlug]">,
) {
  const { organizationSlug } = await props.params;
  const { organization } =
    await requireOrganizationMembership(organizationSlug);

  const supabase = await createClient();
  const organizations = await listMyOrganizations(supabase);

  return (
    <div className="flex min-h-full flex-1 flex-col">
      <header className="flex flex-wrap items-center justify-between gap-3 border-b border-zinc-200 px-6 py-4 dark:border-zinc-800">
        <div className="flex flex-wrap items-center gap-4">
          <span className="text-lg font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
            {organization.name}
          </span>
          <OrganizationSwitcher
            organizations={organizations}
            activeSlug={organizationSlug}
          />
          <nav className="flex items-center gap-4 text-sm font-medium text-zinc-600 dark:text-zinc-400">
            <Link
              href={`/dashboard/${organizationSlug}`}
              className="hover:text-zinc-950 dark:hover:text-zinc-50"
            >
              Dashboard
            </Link>
            <Link
              href={`/dashboard/${organizationSlug}/events`}
              className="hover:text-zinc-950 dark:hover:text-zinc-50"
            >
              Events
            </Link>
          </nav>
        </div>
        <SignOutButton />
      </header>
      <div className="flex-1 px-6 py-8">{props.children}</div>
    </div>
  );
}
