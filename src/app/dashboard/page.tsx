import { redirect } from "next/navigation";

import { resolveLandingPath } from "@/features/organizations/server/resolve-landing-path";
import { requireUser } from "@/lib/auth/require-user";
import { createClient } from "@/lib/supabase/server";

/**
 * The slug-less `/dashboard` is never a real destination — it always
 * redirects, either to the user's first organization or to `/onboarding`
 * if they have none. See RFC-003 "Redirect behavior".
 */
export default async function DashboardIndexPage() {
  await requireUser("/dashboard");
  const supabase = await createClient();

  redirect(await resolveLandingPath(supabase));
}
