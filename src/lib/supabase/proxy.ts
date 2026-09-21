import "server-only";

import { createServerClient } from "@supabase/ssr";
import { NextResponse, type NextRequest } from "next/server";

import { getServerEnv, isServerEnvConfigured } from "@/lib/env/server";

/**
 * Refreshes the Supabase auth session on every request and keeps the
 * browser's auth cookies in sync. Invoked from `src/proxy.ts`, which runs
 * on (almost) every request — see the guard below before changing this.
 *
 * This performs token refresh ONLY. It does not redirect unauthenticated
 * requests, check organization membership, or enforce any authorization —
 * that's business/authorization logic for a later RFC, and per Next.js's
 * own guidance it must be re-verified inside each Server Action / Route
 * Handler rather than assumed from proxy having run.
 */
export async function updateSession(request: NextRequest) {
  const response = NextResponse.next({ request });

  if (!isServerEnvConfigured()) {
    // Supabase hasn't been configured yet (e.g. a fresh RFC-001 checkout
    // before `.env.local` is filled in from `.env.example`). There's no
    // auth flow yet for session refresh to protect, so let the request
    // through rather than taking down every page in the app — the minimal
    // homepage must render without a Supabase project configured.
    // `lib/supabase/server.ts` / `client.ts` still fail loudly the moment
    // something actually tries to talk to Supabase without configuration.
    return response;
  }

  const serverEnv = getServerEnv();
  let currentResponse = response;

  const supabase = createServerClient(
    serverEnv.NEXT_PUBLIC_SUPABASE_URL,
    serverEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    {
      cookies: {
        getAll() {
          return request.cookies.getAll();
        },
        setAll(cookiesToSet) {
          for (const { name, value } of cookiesToSet) {
            request.cookies.set(name, value);
          }

          currentResponse = NextResponse.next({ request });

          for (const { name, value, options } of cookiesToSet) {
            currentResponse.cookies.set(name, value, options);
          }
        },
      },
    },
  );

  // Touching the session lets @supabase/ssr refresh an expiring token and
  // write the updated cookies back via `setAll` above. Do this before
  // anything else reads the request in a real handler, or a refresh that
  // completes after the response is sent will be lost.
  await supabase.auth.getClaims();

  return currentResponse;
}
