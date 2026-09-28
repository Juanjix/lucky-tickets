import "server-only";

import { randomBytes, createHash } from "node:crypto";

/**
 * Checkout access token generation (RFC-006 sections 24/25).
 *
 * Knowing an order's UUID must never be sufficient to read it back
 * (section 23) - a buyer also needs a raw token that only they were ever
 * shown. That token is generated HERE, in trusted server-side Node code,
 * using `crypto.randomBytes` (never `Math.random()`, which is not
 * cryptographically secure and must never be used for anything
 * security-sensitive). It is hashed with SHA-256 before it ever reaches
 * Postgres: `create_order_with_hold` and `get_checkout_order` only ever
 * see/store/compare the hash (`orders.checkout_token_hash`), never the raw
 * value. The raw token is returned to the caller (`POST /api/checkout`'s
 * response) exactly once and must never be logged or persisted anywhere.
 */

/** 32 random bytes (256 bits) hex-encoded -> a 64-character token. Unguessable; far more entropy than needed. */
const RAW_TOKEN_BYTES = 32;

/** Generates a new cryptographically random raw checkout token. Never persisted as-is - see `hashCheckoutToken`. */
export function generateCheckoutToken(): string {
  return randomBytes(RAW_TOKEN_BYTES).toString("hex");
}

/** Deterministically hashes a raw checkout token (SHA-256, hex-encoded) for storage/comparison. The raw token cannot be recovered from this hash. */
export function hashCheckoutToken(rawToken: string): string {
  return createHash("sha256").update(rawToken, "utf8").digest("hex");
}
