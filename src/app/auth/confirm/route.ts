import type { EmailOtpType } from "@supabase/supabase-js";
import { redirect } from "next/navigation";
import { type NextRequest } from "next/server";

import { createClient } from "@/lib/supabase/server";

/**
 * Completes Supabase Auth's email confirmation link (`signUpAction` sets
 * `emailRedirectTo` to this route). Not a magic link or passwordless sign-in
 * — RFC-003 explicitly excludes those — this only finishes the ordinary
 * password sign-up flow when the Supabase project has "Confirm email"
 * turned on. `type`/`token_hash` come from Supabase's own generated link,
 * not from anything a client can otherwise influence.
 */
export async function GET(request: NextRequest) {
  const { searchParams } = new URL(request.url);
  const tokenHash = searchParams.get("token_hash");
  const type = searchParams.get("type") as EmailOtpType | null;
  const next = searchParams.get("next") ?? "/onboarding";

  if (tokenHash && type) {
    const supabase = await createClient();
    const { error } = await supabase.auth.verifyOtp({
      type,
      token_hash: tokenHash,
    });

    if (!error) {
      redirect(next.startsWith("/") ? next : "/onboarding");
    }
  }

  redirect("/login?error=confirmation_failed");
}
