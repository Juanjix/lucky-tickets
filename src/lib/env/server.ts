import "server-only";

import { z } from "zod";

/**
 * Server-only environment variables.
 *
 * The `server-only` import above makes this module throw a build error if
 * anything tries to import it from client code, so a secret added here can
 * never leak into the browser bundle by accident.
 *
 * This schema only re-validates the same public Supabase values the
 * client uses, because the server Supabase client (`../supabase/server.ts`)
 * needs them too. It is intentionally NOT where RFC-007's Mercado
 * Pago/service-role secrets live (see `getPaymentServerEnv` below) -
 * `getServerEnv`/`isServerEnvConfigured` are called from `src/proxy.ts` on
 * EVERY request to decide whether to attempt a Supabase session refresh,
 * so widening this particular schema would make every page in the app
 * (including ones with nothing to do with payments) fail if a Mercado
 * Pago credential were ever missing.
 */
const serverEnvSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url({
    message: "NEXT_PUBLIC_SUPABASE_URL must be a valid Supabase project URL",
  }),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z
    .string()
    .min(1, "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY is required"),
});

function readRawServerEnv() {
  return {
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  };
}

/**
 * Validates and returns the server env vars, throwing a clear error if any
 * are missing or invalid. Called lazily, from wherever the values are
 * actually needed (e.g. `lib/supabase/server.ts`, when a Supabase client is
 * actually constructed) — importing this module on its own does not
 * require configuration. This matters because `src/proxy.ts` runs on every
 * request: it uses `isServerEnvConfigured` below to skip session refresh
 * gracefully instead of taking down every page when Supabase hasn't been
 * configured yet.
 */
export function getServerEnv() {
  const parsed = serverEnvSchema.safeParse(readRawServerEnv());

  if (!parsed.success) {
    const issues = parsed.error.issues
      .map(
        (issue) => `  - ${issue.path.join(".") || "(root)"}: ${issue.message}`,
      )
      .join("\n");

    throw new Error(
      `Invalid server environment variables. Check your .env.local against .env.example:\n${issues}`,
    );
  }

  return parsed.data;
}

/** True if all server env vars are present and valid, without throwing. */
export function isServerEnvConfigured(): boolean {
  return serverEnvSchema.safeParse(readRawServerEnv()).success;
}

/**
 * RFC-007's payment-specific server-only secrets, deliberately kept in a
 * SEPARATE schema/function from `getServerEnv` above (see that schema's
 * doc comment for why): only code that actually needs to talk to Mercado
 * Pago or use the service-role Supabase client
 * (`src/lib/mercado-pago/*`, `src/lib/supabase/service-role.ts`,
 * `src/app/api/payments/**`, `src/app/api/webhooks/**`) calls this, so a
 * missing Mercado Pago credential never breaks unrelated pages/routes.
 *
 * `NEXT_PUBLIC_APP_URL` is included here (not in `./client.ts`) because,
 * today, only server code (building Mercado Pago back_urls/notification_url)
 * reads it - see RFC-007 section 16 and section 48 ("do not implement
 * arbitrary redirect URLs from browser input... return URLs must derive
 * from trusted application configuration").
 */
const paymentServerEnvSchema = z.object({
  MERCADO_PAGO_ACCESS_TOKEN: z
    .string()
    .min(1, "MERCADO_PAGO_ACCESS_TOKEN is required"),
  MERCADO_PAGO_WEBHOOK_SECRET: z
    .string()
    .min(1, "MERCADO_PAGO_WEBHOOK_SECRET is required"),
  NEXT_PUBLIC_APP_URL: z.url({
    message: "NEXT_PUBLIC_APP_URL must be a valid absolute URL",
  }),
  SUPABASE_SERVICE_ROLE_KEY: z
    .string()
    .min(1, "SUPABASE_SERVICE_ROLE_KEY is required"),
});

function readRawPaymentServerEnv() {
  return {
    MERCADO_PAGO_ACCESS_TOKEN: process.env.MERCADO_PAGO_ACCESS_TOKEN,
    MERCADO_PAGO_WEBHOOK_SECRET: process.env.MERCADO_PAGO_WEBHOOK_SECRET,
    NEXT_PUBLIC_APP_URL: process.env.NEXT_PUBLIC_APP_URL,
    SUPABASE_SERVICE_ROLE_KEY: process.env.SUPABASE_SERVICE_ROLE_KEY,
  };
}

/** Validates and returns RFC-007's payment/service-role env vars, throwing a clear error if any are missing or invalid. */
export function getPaymentServerEnv() {
  const parsed = paymentServerEnvSchema.safeParse(readRawPaymentServerEnv());

  if (!parsed.success) {
    const issues = parsed.error.issues
      .map(
        (issue) => `  - ${issue.path.join(".") || "(root)"}: ${issue.message}`,
      )
      .join("\n");

    throw new Error(
      `Invalid payment environment variables. Check your .env.local against .env.example:\n${issues}`,
    );
  }

  return parsed.data;
}
