#!/usr/bin/env node
// RFC-007 deterministic, dependency-free unit tests for Mercado Pago webhook
// signature verification (src/lib/mercado-pago/signature.ts).
//
// Why this script exists rather than a Vitest/Jest test file: this project
// currently has zero test-runner dependency (see package.json - only
// next/eslint/prettier/typescript). Introducing a full test framework
// purely to cover one pure-function module would be disproportionate
// infrastructure for RFC-007's scope ("avoid overengineering" - RFC-007
// section 61) and is left as a documented recommendation for a future RFC
// (see docs/rfcs/RFC-007-mercado-pago-payments.md "Known limitations")
// rather than done here. Instead, this script exercises the algorithm with
// plain Node + assert, deterministically, with zero network/database/live
// Mercado Pago dependency, and can be run in CI or locally with nothing
// beyond Node itself:
//
//   node scripts/test-mercado-pago-signature.ts
//
// It tests the REAL, actual source file (not a hand-duplicated copy that
// could silently drift from it): src/lib/mercado-pago/signature.ts starts
// with `import "server-only";` (intentional - RFC-007 section 63: "Modules
// with credentials must be server-only"), which throws immediately if
// imported outside a Next.js server bundle (plain Node has no bundler
// aliasing for it). Rather than weakening that guard to ease testing, this
// script reads the real file's source text, strips only that one
// import-for-its-side-effect-only line, writes the result to a throwaway
// temp file, and dynamically imports THAT - so every other line, and the
// exported functions' actual behavior, is the genuine, unmodified
// implementation.

import { createHmac } from "node:crypto";
import { readFileSync, writeFileSync, mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { pathToFileURL } from "node:url";

const SOURCE_PATH = new URL(
  "../src/lib/mercado-pago/signature.ts",
  import.meta.url,
);

function loadRealModuleWithoutServerOnlyGuard() {
  const source = readFileSync(SOURCE_PATH, "utf8");
  const stripped = source.replace(/^import "server-only";\n/, "");
  if (stripped === source) {
    throw new Error(
      'Expected signature.ts to start with `import "server-only";` - the guard this script strips was not found. Update this script if that import was intentionally removed or changed.',
    );
  }
  const dir = mkdtempSync(join(tmpdir(), "rfc007-signature-test-"));
  const tempPath = join(dir, "signature.ts");
  // Node's native TypeScript support (--experimental-strip-types) only
  // erases types, it does not transform module syntax - this file only
  // uses plain `export function`/type annotations, which it fully
  // supports.
  writeFileSync(tempPath, stripped, "utf8");
  return pathToFileURL(tempPath).href;
}

let failures = 0;
let count = 0;

function assertEqual(actual, expected, label) {
  count += 1;
  const ok = actual === expected;
  if (!ok) {
    failures += 1;
    console.error(
      `FAIL [${count}] ${label}\n  expected: ${JSON.stringify(expected)}\n  actual:   ${JSON.stringify(actual)}`,
    );
  } else {
    console.log(`PASS [${count}] ${label}`);
  }
}

async function main() {
  const moduleUrl = loadRealModuleWithoutServerOnlyGuard();
  const { parseSignatureHeader, buildManifest, verifyWebhookSignature } =
    await import(moduleUrl);

  // ---------------------------------------------------------------------
  // parseSignatureHeader
  // ---------------------------------------------------------------------
  assertEqual(
    JSON.stringify(parseSignatureHeader("ts=1700000000000,v1=abc123")),
    JSON.stringify({ ts: "1700000000000", v1: "abc123" }),
    "parseSignatureHeader parses a well-formed ts=...,v1=... header",
  );

  assertEqual(
    parseSignatureHeader(null),
    null,
    "parseSignatureHeader returns null for a missing (null) header",
  );

  assertEqual(
    parseSignatureHeader(""),
    null,
    "parseSignatureHeader returns null for an empty header",
  );

  assertEqual(
    parseSignatureHeader("ts=1700000000000"),
    null,
    "parseSignatureHeader returns null when v1 is missing",
  );

  assertEqual(
    parseSignatureHeader("v1=abc123"),
    null,
    "parseSignatureHeader returns null when ts is missing",
  );

  assertEqual(
    parseSignatureHeader("not-a-valid-header-at-all"),
    null,
    "parseSignatureHeader returns null for a garbage/malformed header",
  );

  assertEqual(
    JSON.stringify(
      parseSignatureHeader("ts=1700000000000,v1=abc123,extra=ignored"),
    ),
    JSON.stringify({ ts: "1700000000000", v1: "abc123" }),
    "parseSignatureHeader ignores unknown extra key=value segments",
  );

  // ---------------------------------------------------------------------
  // buildManifest - including the "omit the whole segment, don't leave it
  // blank" nuance and the lowercase(data.id) nuance (RFC-007 section 20).
  // ---------------------------------------------------------------------
  assertEqual(
    buildManifest({
      dataId: "123456789",
      requestId: "req-abc-1",
      ts: "1700000000000",
    }),
    "id:123456789;request-id:req-abc-1;ts:1700000000000;",
    "buildManifest includes all three segments in the documented order when all inputs are present",
  );

  assertEqual(
    buildManifest({ dataId: "ABCDEF12", requestId: "req-1", ts: "111" }),
    "id:abcdef12;request-id:req-1;ts:111;",
    "buildManifest lowercases data.id before including it",
  );

  assertEqual(
    buildManifest({ dataId: null, requestId: "req-1", ts: "111" }),
    "request-id:req-1;ts:111;",
    "buildManifest OMITS the id: segment entirely (not id:;) when dataId is absent",
  );

  assertEqual(
    buildManifest({ dataId: "123", requestId: null, ts: "111" }),
    "id:123;ts:111;",
    "buildManifest OMITS the request-id: segment entirely when requestId is absent",
  );

  assertEqual(
    buildManifest({ dataId: null, requestId: null, ts: "111" }),
    "ts:111;",
    "buildManifest still includes ts: when both dataId and requestId are absent",
  );

  // ---------------------------------------------------------------------
  // verifyWebhookSignature - end-to-end valid/invalid/missing/tampered
  // ---------------------------------------------------------------------
  const secret = "test-webhook-secret-do-not-use-in-production";
  const dataId = "987654321";
  const requestId = "req-xyz-1";
  const ts = "1700000000000";
  const manifest = buildManifest({ dataId, requestId, ts });
  const validHex = createHmac("sha256", secret)
    .update(manifest, "utf8")
    .digest("hex");
  const validHeader = `ts=${ts},v1=${validHex}`;

  assertEqual(
    verifyWebhookSignature({
      signatureHeader: validHeader,
      requestId,
      dataId,
      secret,
    }),
    true,
    "verifyWebhookSignature accepts a genuinely valid signature",
  );

  assertEqual(
    verifyWebhookSignature({
      signatureHeader: validHeader,
      requestId,
      dataId,
      secret: "a-completely-different-secret",
    }),
    false,
    "verifyWebhookSignature rejects a valid manifest signed with the WRONG secret",
  );

  assertEqual(
    verifyWebhookSignature({
      signatureHeader: null,
      requestId,
      dataId,
      secret,
    }),
    false,
    "verifyWebhookSignature rejects a missing signature header",
  );

  assertEqual(
    verifyWebhookSignature({
      signatureHeader: "ts=1700000000000",
      requestId,
      dataId,
      secret,
    }),
    false,
    "verifyWebhookSignature rejects a header missing v1 (malformed)",
  );

  const tamperedHex =
    validHex.slice(0, -2) + (validHex.slice(-2) === "00" ? "11" : "00");
  assertEqual(
    verifyWebhookSignature({
      signatureHeader: `ts=${ts},v1=${tamperedHex}`,
      requestId,
      dataId,
      secret,
    }),
    false,
    "verifyWebhookSignature rejects a tampered v1 hash (last byte flipped)",
  );

  assertEqual(
    verifyWebhookSignature({
      signatureHeader: validHeader,
      requestId,
      dataId: "111111111", // attacker changed which payment this claims to be about
      secret,
    }),
    false,
    "verifyWebhookSignature rejects a valid header replayed against a DIFFERENT data.id (manifest no longer matches)",
  );

  assertEqual(
    verifyWebhookSignature({
      signatureHeader: validHeader,
      requestId: "a-different-request-id",
      dataId,
      secret,
    }),
    false,
    "verifyWebhookSignature rejects a valid header replayed with a different x-request-id",
  );

  assertEqual(
    verifyWebhookSignature({
      signatureHeader: `ts=${ts},v1=not-valid-hex`,
      requestId,
      dataId,
      secret,
    }),
    false,
    "verifyWebhookSignature rejects a non-hex v1 value without throwing",
  );

  assertEqual(
    verifyWebhookSignature({
      signatureHeader: `ts=${ts},v1=ab`, // valid hex, wrong length vs. a real 32-byte SHA-256 digest
      requestId,
      dataId,
      secret,
    }),
    false,
    "verifyWebhookSignature rejects a wrong-length v1 without throwing (timingSafeEqual length-mismatch guard)",
  );

  console.log(`\n${count - failures}/${count} assertions passed.`);
  if (failures > 0) {
    console.error(`${failures} assertion(s) FAILED.`);
    process.exit(1);
  }
}

main().catch((error) => {
  console.error("Test script crashed:", error);
  process.exit(1);
});
