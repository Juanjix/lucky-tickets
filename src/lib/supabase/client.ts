import { createBrowserClient } from "@supabase/ssr";

import { getClientEnv } from "@/lib/env/client";
import type { Database } from "@/types/database";

/**
 * Supabase client for use in Client Components.
 *
 * Call this where it's needed (a component, a hook) rather than importing a
 * shared instance — `@supabase/ssr` manages the underlying singleton and
 * cookie sync for you. Never treat data returned from this client as
 * authorization: RLS policies are what actually enforce access.
 *
 * Parameterized with the generated `Database` type (RFC-002/RFC-003) so
 * every `.from(...)`/`.rpc(...)` call is checked against the real schema —
 * see `src/types/database.ts` and `docs/database.md`.
 */
export function createClient() {
  const clientEnv = getClientEnv();

  return createBrowserClient<Database>(
    clientEnv.NEXT_PUBLIC_SUPABASE_URL,
    clientEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  );
}
