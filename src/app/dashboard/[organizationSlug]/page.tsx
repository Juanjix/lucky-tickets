import { requireOrganizationMembership } from "@/lib/auth/require-organization";

export default async function OrganizationDashboardPage(
  props: PageProps<"/dashboard/[organizationSlug]">,
) {
  const { organizationSlug } = await props.params;
  const searchParams = await props.searchParams;
  const { organization, membership } =
    await requireOrganizationMembership(organizationSlug);

  const forbidden = searchParams.error === "forbidden";

  return (
    <div className="flex flex-col gap-6">
      {forbidden ? (
        <p
          role="alert"
          className="rounded-md border border-red-300 bg-red-50 px-4 py-3 text-sm text-red-800 dark:border-red-900 dark:bg-red-950 dark:text-red-200"
        >
          You don&apos;t have permission to view that page.
        </p>
      ) : null}

      <div className="flex flex-col gap-1">
        <h1 className="text-xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
          {organization.name}
        </h1>
        <p className="text-sm text-zinc-600 dark:text-zinc-400">
          You are signed in as {membership.role.toLowerCase()}.
        </p>
      </div>

      <p className="max-w-prose text-sm text-zinc-600 dark:text-zinc-400">
        This is the foundation for {organization.name}&apos;s dashboard. Event
        management, ticketing, and everything else arrive in later RFCs — see
        docs/rfcs/RFC-003-auth-organizations.md for what this RFC establishes.
      </p>
    </div>
  );
}
