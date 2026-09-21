import "server-only";

import { cookies } from "next/headers";
import { createServerClient } from "@supabase/ssr";

import { getServerEnv } from "@/lib/env/server";

/**
 * Supabase client for use in Server Components, Server Actions, and Route
 * Handlers.
 *
 * Create a new instance per request (call this function again) — never
 * share or cache one across requests. Writing cookies from a Server
 * Component isn't possible in Next.js, so `setAll` below is wrapped in a
 * try/catch; that's safe as long as `src/proxy.ts` is refreshing the
 * session on every request (see `src/lib/supabase/proxy.ts`).
 */
export async function createClient() {
  const cookieStore = await cookies();
  const serverEnv = getServerEnv();

  return createServerClient(
    serverEnv.NEXT_PUBLIC_SUPABASE_URL,
    serverEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    {
      cookies: {
        getAll() {
          return cookieStore.getAll();
        },
        setAll(cookiesToSet) {
          try {
            for (const { name, value, options } of cookiesToSet) {
              cookieStore.set(name, value, options);
            }
          } catch {
            // Called from a Server Component — ignored, see note above.
          }
        },
      },
    },
  );
}
