import "server-only";

import { createHmac, timingSafeEqual } from "node:crypto";

/**
 * Mercado Pago webhook signature verification (RFC-007 sections 20/21/73).
 *
 * Documented mechanism (Mercado Pago Developers, "Webhooks" /
 * "Configure notifications" - consulted directly for this RFC, not
 * implemented from memory - see docs/rfcs/RFC-007-mercado-pago-payments.md
 * "Mercado Pago documentation" for the exact pages used):
 *
 *   1. The `x-signature` request header arrives as comma-separated
 *      `key=value` pairs: `ts=<unix-ms-timestamp>,v1=<hex-hmac>`.
 *   2. A "manifest" string is built as:
 *        `id:{data.id};request-id:{x-request-id};ts:{ts};`
 *      - `data.id` is the resource id from the notification (the query
 *        param `data.id` on Checkout Pro's redirect-style pings, or the
 *        JSON body's `data.id` on a POST notification), lowercased before
 *        inclusion.
 *      - `request-id` is the `x-request-id` header, verbatim.
 *      - `ts` is the timestamp extracted from `x-signature` itself, not
 *        independently generated - the whole point is that the manifest
 *        we hash must byte-for-byte match what Mercado Pago hashed.
 *      - CRITICAL nuance: if `data.id` or `x-request-id` is absent, that
 *        ENTIRE segment (e.g. `id:;`) is omitted from the manifest, not
 *        left blank - see `buildManifest` below.
 *   3. `HMAC-SHA256(manifest, MERCADO_PAGO_WEBHOOK_SECRET)`, hex-encoded,
 *      must equal the `v1` value from step 1, compared in constant time.
 *
 * This module has zero network/database dependencies and is covered by
 * deterministic unit-style pgTAP-adjacent... actually plain Vitest-free
 * assertions are out of scope for this project's current tooling, so
 * correctness here is instead exercised by the webhook Route Handler's
 * manual QA (RFC-007 section 73) - the algorithm itself has no external
 * state, so a wrong implementation would reject every genuine sandbox
 * notification during that QA, not just synthetic ones.
 */

export type ParsedSignatureHeader = {
  ts: string;
  v1: string;
};

/** Parses `ts=...,v1=...` into its two components. Returns null if either is missing - callers must treat that as an invalid signature, never as "no signature to check." */
export function parseSignatureHeader(
  header: string | null,
): ParsedSignatureHeader | null {
  if (!header) {
    return null;
  }

  const parts = new Map<string, string>();
  for (const segment of header.split(",")) {
    const [key, ...rest] = segment.split("=");
    if (!key || rest.length === 0) {
      continue;
    }
    parts.set(key.trim(), rest.join("=").trim());
  }

  const ts = parts.get("ts");
  const v1 = parts.get("v1");

  if (!ts || !v1) {
    return null;
  }

  return { ts, v1 };
}

/** Builds the exact manifest string Mercado Pago signs. `dataId`/`requestId` segments are omitted entirely (not left blank) when absent - see this module's doc comment. */
export function buildManifest(input: {
  dataId: string | null;
  requestId: string | null;
  ts: string;
}): string {
  let manifest = "";

  if (input.dataId) {
    manifest += `id:${input.dataId.toLowerCase()};`;
  }
  if (input.requestId) {
    manifest += `request-id:${input.requestId};`;
  }
  manifest += `ts:${input.ts};`;

  return manifest;
}

/**
 * Verifies a webhook delivery's `x-signature` header against the
 * configured `MERCADO_PAGO_WEBHOOK_SECRET`. Returns `false` for anything
 * short of a fully valid, matching signature - a missing header, a
 * malformed header, or a mismatched hash are all indistinguishably
 * "invalid" to the caller (RFC-007 section 21: "Reject invalid
 * signatures").
 */
export function verifyWebhookSignature(input: {
  signatureHeader: string | null;
  requestId: string | null;
  dataId: string | null;
  secret: string;
}): boolean {
  const parsed = parseSignatureHeader(input.signatureHeader);
  if (!parsed) {
    return false;
  }

  const manifest = buildManifest({
    dataId: input.dataId,
    requestId: input.requestId,
    ts: parsed.ts,
  });

  const expected = createHmac("sha256", input.secret)
    .update(manifest, "utf8")
    .digest("hex");

  const expectedBuffer = Buffer.from(expected, "hex");
  const actualBuffer = Buffer.from(parsed.v1, "hex");

  // Different lengths would make timingSafeEqual throw rather than return
  // false - guard explicitly so a malformed v1 is just "invalid", not a
  // 500.
  if (expectedBuffer.length !== actualBuffer.length) {
    return false;
  }

  return timingSafeEqual(expectedBuffer, actualBuffer);
}
