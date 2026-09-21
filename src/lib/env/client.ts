import { z } from "zod";

/**
 * Environment variables that are safe to expose to the browser.
 *
 * Next.js inlines `NEXT_PUBLIC_*` variables into the client bundle at build
 * time, so only ever put values here that are safe for any visitor to read
 * (a project URL, a publishable/anon API key). Anything sensitive belongs in
 * `./server.ts` instead, which is guarded so it can never be imported by
 * client code.
 *
 * References are written out individually (not looped) so Next.js's
 * static replacement of `process.env.NEXT_PUBLIC_*` can find them.
 */
const clientEnvSchema = z.object({
  NEXT_PUBLIC_SUPABASE_URL: z.url({
    message: "NEXT_PUBLIC_SUPABASE_URL must be a valid Supabase project URL",
  }),
  NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY: z
    .string()
    .min(1, "NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY is required"),
});

function readRawClientEnv() {
  return {
    NEXT_PUBLIC_SUPABASE_URL: process.env.NEXT_PUBLIC_SUPABASE_URL,
    NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY:
      process.env.NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY,
  };
}

/**
 * Validates and returns the public env vars, throwing a clear error if any
 * are missing or invalid. Called lazily, from wherever the values are
 * actually needed (e.g. `lib/supabase/client.ts`) — importing this module
 * on its own does not require configuration.
 */
export function getClientEnv() {
  const parsed = clientEnvSchema.safeParse(readRawClientEnv());

  if (!parsed.success) {
    const issues = parsed.error.issues
      .map(
        (issue) => `  - ${issue.path.join(".") || "(root)"}: ${issue.message}`,
      )
      .join("\n");

    throw new Error(
      `Invalid public environment variables. Check your .env.local against .env.example:\n${issues}`,
    );
  }

  return parsed.data;
}

/** True if all public env vars are present and valid, without throwing. */
export function isClientEnvConfigured(): boolean {
  return clientEnvSchema.safeParse(readRawClientEnv()).success;
}
