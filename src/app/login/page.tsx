import { redirect } from "next/navigation";

import { LoginForm } from "@/features/auth/components/login-form";
import { resolveLandingPath } from "@/features/organizations/server/resolve-landing-path";
import { getOptionalUser } from "@/lib/auth/require-user";
import { createClient } from "@/lib/supabase/server";

export default async function LoginPage(props: PageProps<"/login">) {
  const searchParams = await props.searchParams;
  const nextParam = searchParams.next;
  const nextPath = typeof nextParam === "string" ? nextParam : undefined;

  // Redirect behavior: an already-authenticated visitor to /login goes
  // straight to their first organization (or /onboarding) rather than
  // seeing the sign-in form again - see RFC-003 "Redirect behavior".
  const user = await getOptionalUser();

  if (user) {
    const supabase = await createClient();
    redirect(await resolveLandingPath(supabase));
  }

  return (
    <main className="flex flex-1 flex-col items-center justify-center gap-6 px-6 py-16">
      <h1 className="text-2xl font-semibold tracking-tight text-zinc-950 dark:text-zinc-50">
        Sign in
      </h1>
      <LoginForm nextPath={nextPath} />
    </main>
  );
}
