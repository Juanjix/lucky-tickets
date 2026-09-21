import { createBrowserClient } from "@supabase/ssr";

import { getClientEnv } from "@/lib/env/client";

/**
 * Supabase client for use in Client Components.
 *
 * Call this where it's needed (a component, a hook) rather than importing a
 * shared instance — `@supabase/ssr` manages the underlying singleton and
 * cookie sync for you. Never treat data returned from this client as
 * authorization: RLS policies (added when domain tables exist) are what
 * actually enforce access.
 */
export function createClient() {
  const clientEnv = getClientEnv();

  return createBrowserClient(
    clientEnv.NEXT_PUBLIC_SUPABASE_URL,
    clientEnv.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  );
}
