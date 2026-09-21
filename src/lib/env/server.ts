import "server-only";

import { z } from "zod";

/**
 * Server-only environment variables.
 *
 * The `server-only` import above makes this module throw a build error if
 * anything tries to import it from client code, so a future secret added
 * here (a service-role key, a payment provider secret, ...) can never leak
 * into the browser bundle by accident.
 *
 * Today this schema only re-validates the same public Supabase values the
 * client uses, because the server Supabase client (`../supabase/server.ts`)
 * needs them too. As later RFCs introduce genuinely server-only secrets
 * (e.g. `SUPABASE_SERVICE_ROLE_KEY`, a payment provider's API key), add them
 * to this schema — never to `./client.ts`.
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
