import { redirect } from "next/navigation";

import { SignupForm } from "@/features/auth/components/signup-form";
import { resolveLandingPath } from "@/features/organizations/server/resolve-landing-path";
import { getOptionalUser } from "@/lib/auth/require-user";
import { createClient } from "@/lib/supabase/server";

export default async function SignupPage() {
  // Redirect behavior: same as /login - an already-authenticated visitor
  // skips the form. See RFC-003 "Redirect behavior".
  const user = await getOptionalUser();

  if (user) {
    const supabase = await createClient();
    redirect(await resolveLandingPath(supabase));
  }

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 px-6 py-16">
      <h1 className="text-2xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
        Create your account
      </h1>
      <SignupForm />
    </main>
  );
}
