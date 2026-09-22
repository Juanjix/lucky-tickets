import { redirect } from "next/navigation";

import { CreateOrganizationForm } from "@/features/organizations/components/create-organization-form";
import { resolveLandingPath } from "@/features/organizations/server/resolve-landing-path";
import { requireUser } from "@/lib/auth/require-user";
import { createClient } from "@/lib/supabase/server";

export default async function OnboardingPage() {
  const user = await requireUser("/onboarding");
  const supabase = await createClient();

  // Redirect behavior: a user who already belongs to an organization has
  // nothing to do here - send them to their dashboard instead of letting
  // them create an unbounded number of organizations from this screen.
  // See RFC-003 "Redirect behavior".
  const landingPath = await resolveLandingPath(supabase);

  if (landingPath !== "/onboarding") {
    redirect(landingPath);
  }

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 px-6 py-16">
      <div className="flex flex-col items-center gap-2 text-center">
        <h1 className="text-2xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
          Create your organization
        </h1>
        <p className="max-w-sm text-sm text-zinc-600 dark:text-zinc-400">
          {user.email ? `Signed in as ${user.email}. ` : ""}
          This is the account your events, tickets, and team will live under.
          You can create more later.
        </p>
      </div>
      <CreateOrganizationForm />
    </main>
  );
}
