"use client";

import { useRouter } from "next/navigation";

import type { MyOrganization } from "@/features/organizations/server/list-my-organizations";

type OrganizationSwitcherProps = {
  organizations: MyOrganization[];
  activeSlug: string;
};

/**
 * Switching organizations is routing, nothing more: the URL
 * (`/dashboard/[organizationSlug]`) is the source of truth for which
 * organization is active, so this holds no state of its own beyond the
 * native `<select>` element's — see RFC-003 "Organization switcher".
 */
export function OrganizationSwitcher({
  organizations,
  activeSlug,
}: OrganizationSwitcherProps) {
  const router = useRouter();

  if (organizations.length <= 1) {
    return null;
  }

  return (
    <label className="flex items-center gap-2 text-sm text-zinc-700 dark:text-zinc-300">
      <span className="sr-only">Switch organization</span>
      <select
        value={activeSlug}
        onChange={(event) => router.push(`/dashboard/${event.target.value}`)}
        className="rounded-md border border-zinc-300 bg-transparent px-2 py-1.5 text-sm dark:border-zinc-700"
      >
        {organizations.map((organization) => (
          <option key={organization.id} value={organization.slug}>
            {organization.name}
          </option>
        ))}
      </select>
    </label>
  );
}
