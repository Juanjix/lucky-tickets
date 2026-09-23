import "server-only";

import { createClient as createSupabaseClient } from "@supabase/supabase-js";

import { getServerEnv } from "@/lib/env/server";
import type { Database } from "@/types/database";

/**
 * Supabase client for the public, buyer-facing event page (RFC-005) ONLY.
 *
 * This is deliberately NOT `src/lib/supabase/server.ts`: that factory reads
 * the visitor's own cookies via `@supabase/ssr`, so a logged-in visitor's
 * request would run as `authenticated` at the database - meaning what the
 * "public" page shows would depend on who happens to be logged in in that
 * browser. The public boundary RFC-005 establishes
 * (`events_select_public` / `ticket_types_select_public` /
 * `organizations_select_public` in the RFC-005 migration) is scoped to the
 * `anon` role specifically, so this client is built with plain
 * `@supabase/supabase-js` and never touches cookies/session storage at
 * all - it always authenticates as `anon`, for every visitor, logged in or
 * not. That keeps "the public boundary" one crisp Postgres role to reason
 * about and test, instead of a mix of anon-or-authenticated depending on
 * browser state.
 *
 * Never use this client for anything other than the RFC-005 public read
 * path - it cannot read or write anything an organizer's own
 * `authenticated` session could, by construction (RLS grants it nothing
 * beyond what `anon` can see).
 */
export function createPublicClient() {
  const serverEnv = getServerEnv();

  return createSupabaseClient<Database>(
    serverEnv.NEXT_PUBLIC_SUPABASE_URL,
    serverEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    },
  );
}
