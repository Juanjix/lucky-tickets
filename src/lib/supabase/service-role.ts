import "server-only";

import { createClient as createSupabaseClient } from "@supabase/supabase-js";

import { getPaymentServerEnv, getServerEnv } from "@/lib/env/server";
import type { Database } from "@/types/database";

/**
 * Supabase client authenticated as `service_role` - bypasses Row Level
 * Security entirely.
 *
 * RFC-007 section 54: "payment webhook processing may legitimately require
 * a trusted server-side Supabase credential if the existing architecture
 * requires bypassing user RLS." This is that ONE narrow exception. Every
 * other Lucky Ticket feature (RFC-005's public page, RFC-006's anonymous
 * checkout) deliberately uses only the `anon`-role
 * `src/lib/supabase/public.ts` client plus SECURITY DEFINER functions,
 * specifically so no route needs elevated database credentials - see that
 * file's own doc comment and RFC-006's migration header. RFC-007's payment
 * confirmation is different in kind: `confirm_order_payment` is GRANTED
 * to `service_role` ONLY (never anon/authenticated - RFC-007 section 53),
 * precisely because it is the one operation a bare "I know an order id"
 * caller must never be able to invoke. Trusted server code only reaches
 * it after independently verifying a payment with Mercado Pago's own API,
 * and this client is what lets that trusted code make the call at all.
 *
 * Never import this from a client component (the `server-only` guard
 * above enforces that at build time) and never use it for anything other
 * than calling `confirm_order_payment`/webhook bookkeeping RPCs - see
 * `src/features/payments/webhook.ts`, the only current caller.
 */
export function createServiceRoleClient() {
  const serverEnv = getServerEnv();
  const paymentEnv = getPaymentServerEnv();

  return createSupabaseClient<Database>(
    serverEnv.NEXT_PUBLIC_SUPABASE_URL,
    paymentEnv.SUPABASE_SERVICE_ROLE_KEY,
    {
      auth: {
        persistSession: false,
        autoRefreshToken: false,
        detectSessionInUrl: false,
      },
    },
  );
}
