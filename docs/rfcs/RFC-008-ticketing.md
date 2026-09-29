# RFC-008 — Ticket Issuance & Secure QR

## Status

Implemented, then corrected once against a REAL local Supabase stack.
`npm run typecheck`/`lint`/`format:check`/`build` all pass for real (see
"Validation results"). The database layer was first verified only against
a disposable native PostgreSQL 16 instance (Docker was unavailable), which
reported a clean pass but was **not faithful enough**: it masked a
schema-placement bug that only exists on a real Supabase project. Once
Docker became available, an actual `npx supabase test db` run against the
migration surfaced three real bugs — a backward-incompatible `NOT NULL`
column, a backward-incompatible `confirm_order_payment` signature change,
and a `pgcrypto` function unreachable from this schema's `search_path` —
all three are now fixed in the same (still-uncommitted) migration file.
See "Validation results" for the full account, kept honestly separated
into what a substitute Postgres proved versus what the real Supabase run
proved. **Not yet committed or pushed** — per this RFC's own instructions,
this document and the accompanying code are for your review before any
`git commit`/`db push`.

## Problem

RFC-007 gets an order to `PAID` through a server-verified, atomic,
idempotent transition. Nothing yet turns that into something a buyer can
actually use to enter a venue. RFC-008's job is narrow: when (and only
when) an order authoritatively reaches `PAID`, issue exactly one `Ticket`
per purchased unit, each independently identifiable and scannable (RFC-009
will check people in per-ticket, not per-order), with a QR credential that
is cryptographically secure, never stored in plaintext, and — the part
flagged as the hardest and most important to get right — re-displayable to
the buyer on demand without ever having persisted the raw secret anywhere.

## Goals

- Exactly `sum(order_items.quantity)` tickets per `PAID` order, issued
  server-side, atomically, idempotently, and safely under concurrent
  redelivered webhooks.
- Each ticket has its own unguessable, CSPRNG-generated QR secret; the
  database never stores it in plaintext.
- The buyer can reopen their tickets page at any time and see the same
  tickets with working QR codes, without the raw secret ever having lived
  anywhere retrievable in plaintext.
- No client-supplied value (ticket type, quantity, price, event, org,
  status, QR data) is ever trusted for issuance.
- Multi-tenant safety and RLS parity with every other table in this
  schema.
- A basic operator-facing "Issued Tickets" view.

## Non-goals

QR scanning, camera integration, check-in, door-staff workflow, offline
check-in, ticket transfer/resale, Apple/Google Wallet passes, refund
automation, email delivery, PDF tickets, promoters/guest lists, billing,
analytics, native apps. All deferred to RFC-009 or later.

## Precondition check: does RFC-007 actually guarantee `PAID` is trustworthy?

Re-verified fresh against the live source before writing a single line of
RFC-008 code, per this RFC's own instruction to check this first.

`src/app/api/webhooks/mercado-pago/route.ts` → `processMercadoPagoWebhook`
(`src/features/payments/webhook.ts`) does, in this exact order:

1. `verifyWebhookSignature(...)` on the raw request body/headers — returns
   401 with **no database write at all** if invalid. An unauthenticated
   request cannot create so much as a `webhook_events` row.
2. Only after that succeeds: `gateway.getPayment(dataId)` — an
   **independent fetch from Mercado Pago's own API**, using the server's
   own access token. The webhook body's own claimed status/amount fields
   are never used past this point; only what this independent fetch
   returns is.
3. Only after that succeeds: `supabase.rpc("confirm_order_payment", ...)`,
   using values taken exclusively from step 2's response.

`confirm_order_payment` itself (re-read in full from
`supabase/migrations/20260925000000_rfc_007_mercado_pago.sql`) locks the
order row (`for update`) first, is idempotent per
`(provider, provider_payment_id)` via a real unique constraint (not an
application-level check), independently re-validates order state,
currency, and amount, and has **exactly one** `update orders set status =
'PAID'` statement, reached through one code path regardless of whether
this is a normal-window or late-recovery confirmation.

**Finding: no gap.** Browser/redirect signals are never consulted anywhere
in this path — "browser redirect ≠ proof of payment; webhook + independent
provider verification = proof of payment" holds exactly as documented.
This is safe to build ticket issuance on top of. Nothing needed fixing.

This also simplifies RFC-008's own integration: because there is only
**one** place `confirm_order_payment` ever transitions an order to `PAID`
(not several, as a shallower read might suggest), only one call site needs
to trigger issuance — see "Payment → issuance integration" below.

## `back_urls`/`auto_return` audit (the other requested precondition)

Already fixed earlier in this engagement, unrelated to RFC-008's own
scope: `src/services/payment-gateway/mercado-pago-payment-gateway.ts` omits
`auto_return` when `back_urls.success` is a local URL (`isLocalUrl()`),
because Mercado Pago's API rejects `auto_return` with a `localhost`/
`127.0.0.1` return URL. This is a genuine sandbox/local-dev limitation
documented in `docs/rfcs/RFC-007-mercado-pago-payments.md` ("Local webhook
testing"), not something RFC-008 needs to touch — ticket issuance is
triggered exclusively by the webhook path (see above), never by the
buyer's browser landing on `/payment/result`, so it is completely
unaffected by whether the automatic redirect fires. This RFC does not
couple issuance to the redirect working, as instructed.

## Existing schema audit

`tickets` (RFC-002) already existed, fully designed for issuance to be
"deferred to a later RFC" (the table's own comment said exactly that):
`id, organization_id, event_id, order_id, order_item_id, ticket_type_id,
ticket_number, holder_name, holder_email, qr_token_hash, status,
issued_at, checked_in_at, created_at, updated_at`, the `ticket_status`
enum (`VALID, CHECKED_IN, CANCELLED, REFUNDED`) already exactly as
requested, composite `(organization_id, X)` foreign keys to
`events`/`orders`/`order_items`/`ticket_types` (the same pattern used
everywhere else in this schema), and `qr_token_hash` already documented as
"a hash only; raw QR secrets are never persisted" — RFC-002 had already
anticipated this design correctly. RLS (`tickets_select_operator`) already
grants `SELECT` to `OWNER, ADMIN, PRODUCER, DOOR_STAFF, VIEWER` — exactly
the role list this RFC's brief asked for, unchanged. No RLS changes were
needed for the dashboard-read side; only a new write path (issuance) and
a new, narrower buyer-facing read path were needed.

Everything RFC-008 adds is additive: three new `tickets` columns and four
new functions, in one new forward-only migration
(`supabase/migrations/20260928000000_rfc_008_ticketing.sql`).
`get_checkout_order`/RFC-006/RFC-007 migration files are byte-for-byte
untouched; `confirm_order_payment` is redefined via `drop function` +
`create function` in the NEW migration only, the same convention RFC-007
already used to redefine `get_checkout_order`.

## Architecture: where issuance lives

Three shapes were considered (the three named in the brief):

- **(A) Same transaction as the `PAID` transition.** Chosen.
- **(B) An `AFTER UPDATE` trigger on `orders`.**
- **(C) An outbox/job table drained by a worker.**

(B) and (C) both add a second moving part to solve something one
transaction already solves for free, given the precondition-check finding
above: there is exactly **one** `update orders set status = 'PAID'`
statement in the entire codebase. Calling
`issue_tickets_for_order_safe(order_id, qr_key)` immediately after it,
inside the same transaction, means it is **impossible** — not merely
unlikely — for an order to end up `PAID` with zero tickets, even under a
process crash, network partition, or serverless cold-kill between two
statements: they commit or roll back together, by construction, with no
window in between. No new infrastructure (queue, worker, cron) was added,
per the explicit instruction to prefer strong consistency and avoid
unnecessary infrastructure. See ADR-016 in `docs/architecture.md`.

**A ticketing bug must never undo a real payment confirmation.**
`issue_tickets_for_order_safe` wraps the real issuance call in its own
`begin ... exception when others` block — an implicit `plpgsql`
savepoint — and never re-raises. If issuance fails for any reason, only
the work since that savepoint rolls back; the `PAID` transition and every
payment/audit row `confirm_order_payment` already wrote stay committed.
The failure is instead recorded as a `tickets_issuance_failed` `audit_logs`
row (`{order_id, sqlstate, message}` — never the QR key, never a raw QR
secret) for operator diagnosis. This directly answers "how do you diagnose
payment approved but tickets missing": query `audit_logs` for that action.

## Ticket lifecycle

New tickets are always created with `status = 'VALID'`. RFC-008 does not
implement refund-driven cancellation, but the schema does not block a
future `PAID → refund → REFUNDED` path either: `get_order_tickets` and
`issue_tickets_for_order`'s own state check both already accept
`REFUNDED`/`PARTIALLY_REFUNDED` orders (an order can only reach either of
those by having been `PAID` first, so its tickets necessarily already
exist), and nothing about the ticket row shape assumes `status` is
write-once.

## Idempotency

Enforced at the database level, never via an application-level
`if (tickets.length === 0)` check (explicitly flagged in the brief as
concurrency-unsafe, and correctly so). Two schema-level additions make it
so:

- `tickets.ticket_sequence` (new column, **nullable**): 1-based position
  of a ticket within its own `order_item` (1..`quantity`). Nullable, not
  `not null`, specifically so that a ticket row inserted directly (RFC-002's
  own pre-RFC-008 test fixture, or any future manual/legacy insert) never
  violates this constraint — see "Database changes" for the paired `check`
  that still enforces the real invariant.
- `unique (organization_id, order_item_id, ticket_sequence)` (new
  constraint): gives every RFC-008-issued ticket "slot" a single,
  deterministic identity. Two `null` sequences never collide under this
  constraint (standard SQL: `unique` treats `null` as distinct from every
  other value, including another `null`), which is exactly what makes
  nullability safe here.

`issue_tickets_for_order` is one statement:
`insert into tickets (...) select ... from order_items cross join lateral
generate_series(1, quantity) ... on conflict (organization_id,
order_item_id, ticket_sequence) do nothing`. Calling it 1, 5, or 20 times
for the same order — exactly the "Mercado Pago may redeliver the webhook"
scenario the brief calls out — always converges to the same ticket count:
the first successful insert for a given slot wins, every later attempt at
that same slot is silently dropped by the unique index itself, not by
application logic. `order_items` rows are immutable after order creation
(no `UPDATE` policy exists on that table), so "how many tickets should
this order ever have" never changes after the fact either.

This was proven, not just argued: see "Validation results" for the actual
pgTAP assertions and the real concurrent-connection script that exercise
exactly this.

## Concurrency

The unique-constraint mechanism above is what makes concurrent calls safe,
not a lock held for the duration of issuance (the row lock on `orders`
only serializes callers that reach it at the same instant — see
`scripts/rfc-008-concurrency-test.sh`'s actual results, where the winner
among many concurrent callers was determined by that lock, but the
constraint is what guarantees correctness regardless of ordering). A
dedicated script (mirroring `rfc-006`/`rfc-007-concurrency-test.sh`'s
existing pattern) fires many real, concurrent `psql` connections at
`issue_tickets_for_order` for the same never-yet-issued order and asserts
the final ticket count and the count of distinct `(order_item_id,
ticket_sequence)` pairs both equal the order's quantity. This was actually
executed (not only written) — see "Validation results".

## QR secret design — the redisplay problem

This is the part the brief called the most important to get right, so the
full reasoning is here rather than only in code comments (the migration
file's own header comment carries the same content, kept in sync).

**Forbidden sources are never used.** No ticket id, order id, sequential
id, email, hash of any of those, or reused/predictable UUID ever
contributes to a QR secret.

**Generation.** Each ticket's raw QR secret is 32 fresh bytes from
Postgres's own CSPRNG — `pgcrypto`'s `gen_random_bytes`, backed by
OpenSSL's `RAND_bytes`, the same class of primitive `crypto.randomBytes`
uses in Node — hex-encoded to match the exact convention
`src/lib/checkout/token.ts` already established for checkout tokens.

**Why Postgres-side generation, not Node.** The brief's own example
(`crypto.randomBytes(32)`) is a Node API. Two designs were possible: (a)
read `order_items` in Node, generate tokens there, and pass a precomputed
array into a Postgres RPC; or (b) generate everything inside the same
atomic SQL statement as issuance. (a) was rejected specifically because of
the architecture decision above: if issuance must live inside
`confirm_order_payment`'s own transaction to close the crash window
between "order PAID" and "tickets exist," the token generation has to live
there too, or that same crash window reopens one level up (a crash between
Node's token generation and the RPC call would leave a `PAID` order with
no tickets again). Postgres's CSPRNG is a legitimate, audited source of
cryptographically secure randomness — the constraint that actually matters
("not `Math.random()`, not a predictable value derived from other data")
is satisfied; the specific runtime it executes in is a deliberate
trade-off in service of strict transactional consistency, not a shortcut.

**Storage — two derived values, never the raw value.**

1. `qr_token_hash` (existing RFC-002 column) = `sha256(raw token)`, hex —
   exactly the checkout-token convention. Fast, one-way, and all RFC-009
   needs at scan time: hash whatever the scanner reads and look it up with
   a single indexed equality query. No decryption on the hot check-in
   path.
2. `qr_secret_ciphertext` (new column, `bytea`) =
   `pgp_sym_encrypt(raw_token, key, 'cipher-algo=aes256')`. This is what
   makes redisplay possible: the issuing server can decrypt this later,
   on demand, to re-render the exact same QR for the buyer, without the
   raw value ever having been stored anywhere as plaintext.

**The key.** `QR_ENCRYPTION_KEY` (new server-only env var, validated by
`getTicketServerEnv()`) is passed as a **plain call argument** to
`issue_tickets_for_order`/`get_order_tickets` — never written to a table,
column, Postgres setting, or log by this migration. A database leak alone
therefore yields ciphertext plus a one-way hash — never a usable QR code.
This was verified directly, not just asserted: pgTAP assertion 38 (see
"Validation results") proves decrypting with the wrong key fails loudly.

**Why `pgp_sym_encrypt`, not hand-rolled AES-256-GCM.** `pgp_sym_encrypt`
(OpenPGP symmetric encryption via `pgcrypto`) is not an authenticated
(AEAD) cipher the way AES-GCM is. This was a deliberate, considered
trade-off, not an oversight: it is a mature, audited primitive already
bundled with the `pgcrypto` extension this schema already depends on for
`gen_random_uuid()`, it lets encryption happen inside the same
transaction as issuance (the crash-safety argument above), and — most
importantly — this design **never decrypts attacker-supplied ciphertext**.
It only ever decrypts ciphertext the issuing server itself wrote,
retrieved by an already-authorized ticket row lookup. That is exactly the
scenario where AEAD's tamper-detection buys little over a mature
non-AEAD symmetric cipher: there is no ciphertext-substitution attack
surface here, because the attacker never gets to supply ciphertext for
this function to decrypt. `qr_secret_version` (new column, defaults to
`1`) is carried on every row specifically so a future move to per-value
AEAD or a KMS-backed scheme is a new, distinguishable code path, not a
backfill. See ADR-017 in `docs/architecture.md` for the permanent record
of this decision.

**Rejected alternatives** (considered and set aside, for completeness):
a deterministic HMAC-derived QR value (rejected — a QR secret must be
independently unguessable per ticket, not derivable from `HMAC(key,
ticket_id)`, since that would make the "forbidden sources" list
meaningless — a compromised `ticket_id` sequence or the key alone would
compromise every ticket); per-view token rotation (rejected — RFC-009
needs a single stable `qr_token_hash` to validate against per ticket;
rotating it would mean invalidating a printed/saved QR the moment the
buyer reopens the page, which is a worse UX for no real security gain in
this threat model).

## QR content encoding

`lt:v1:<rawToken>` (`src/lib/tickets/qr.ts`), not a URL. Versioned from
day one (`v1`) so RFC-009's scanner can distinguish this generation of
tokens from any future format change without a backfill. Deliberately not
`https://.../t/<token>`: a bare secret string avoids a generic camera
app's "open this link" affordance (the wrong UX for a venue-entry
credential meant for a dedicated scanner, not a browser), keeps the QR
payload smaller and more reliably scannable than a full URL would need,
and avoids the raw secret ever surfacing as a clickable link in a phone's
photo library, notifications, or share sheet.

## Buyer access capability

Deliberately **not** a reuse of the RFC-006/007 checkout token.
`src/features/payments/api.ts` already documents, as an accepted RFC-007
tradeoff, that the raw checkout token travels inside Mercado Pago's
`back_urls` and is therefore retained by Mercado Pago itself. That
exposure is fine for a short-lived "check my payment status" credential;
it is not acceptable for a long-lived credential that unlocks scannable
venue-entry QR codes.

RFC-008 mints a separate, stateless value instead:
`hmac-sha256(TICKET_ACCESS_SIGNING_KEY, "order:" + orderId)`
(`src/lib/tickets/access-token.ts`). A **stored random token** design was
considered and rejected: the webhook handler that would need to mint it
has no channel back to the buyer's browser, which creates an unrecoverable
lockout race — only whichever single request happened to mint it first
could ever learn the raw value. Because the HMAC is a pure function of a
fixed server secret and the order id, it needs **no database storage, no
minting endpoint, and no race** — the payment-status poll that first
observes `PAID`, and the buyer reopening the same link a month later, both
independently recompute and verify the exact same value via
`crypto.timingSafeEqual` (never `===`, which would leak timing
information).

**Delivery: no new endpoint.** The token is handed to the buyer by
extending the _existing_ `GET /api/orders/[orderId]/payment-status`
response (`src/features/payments/queries.ts`'s `getPaymentStatus`) with an
optional `ticketsUrl` field, populated only once the (existing) status
fold reaches `PAID`. `payment-status-view.tsx`'s existing 2-second polling
loop (unchanged in its own logic) now also reads this field and renders a
"Ver mis entradas" button the moment it appears — this is literally the
same polling RFC-007 already built, not a second poller, and no new route
was added.

**The read boundary.** `get_order_tickets` (new function) is granted to
`service_role` only — exactly `confirm_order_payment`'s own trust shape
(ADR-014), applied to a read: the capability token is verified in Node
(`src/features/tickets/queries.ts`'s `getOrderTicketsForBuyer`, via
`verifyTicketAccessToken`) **before** the database is ever touched. An
order id alone, or even an order id with a well-formed-looking but wrong
token, is never sufficient — verification happens first, in
`timingSafeEqual`, with a short-circuit before any RPC call. `GET
/tickets/<random-order-uuid>` alone can never work: the page
(`src/app/tickets/order/[orderId]/page.tsx`) requires `?token=...` and
renders the exact same `notFound()` for "wrong token," "no such order,"
and "order never paid" (the same not-found-boundary convention RFC-006/007
already use for an invalid checkout token — never letting a caller
distinguish which case they hit).

## RLS / multi-tenancy

No RLS policy changed. `tickets_select_operator` (RFC-002) already granted
exactly the role list requested (`OWNER, ADMIN, PRODUCER, DOOR_STAFF,
VIEWER`) and needed no changes for the dashboard-read side. The two new
write-capable functions (`issue_tickets_for_order`,
`issue_tickets_for_order_safe`) and the new buyer-facing read function
(`get_order_tickets`) are all `security definer`, with `execute` explicitly
revoked from `public`/`anon`/`authenticated` and granted to `service_role`
only — mirroring `confirm_order_payment`'s own grant pattern exactly.
Every new `tickets` row inherits its `organization_id`/`event_id`/
`ticket_type_id` directly from the `order_items`/`orders` row it was
derived from (the same composite-FK pattern RFC-002 already established
for `tickets`), so a ticket can never end up attached to the wrong tenant
— this is a schema-level guarantee, not an application-level one, proven
by pgTAP assertion 20 and the tenant-isolation assertions 47/48.

## No client trust

`issue_tickets_for_order` takes exactly two arguments: `p_order_id` and
`p_qr_encryption_key`. It accepts no `ticket_type_id`, `quantity`, price,
`event_id`, `organization_id`, status, or QR data from its caller — every
value is derived exclusively from `order_items`/`orders`/`ticket_types`
rows already tied together by existing foreign keys.

## Database changes

New migration: `supabase/migrations/20260928000000_rfc_008_ticketing.sql`
(forward-only; RFC-002 through RFC-007 migration files are untouched).

- `tickets` gains three columns: `ticket_sequence integer` (**nullable**
  — see "Idempotency" above), `qr_secret_ciphertext bytea` (**nullable**,
  same reasoning), `qr_secret_version smallint not null default 1`; plus
  `unique (organization_id, order_item_id, ticket_sequence)`, a
  `ticket_sequence > 0` check, and a new
  `check ((ticket_sequence is null) = (qr_secret_ciphertext is null))`
  constraint — this is what actually carries the "every RFC-008-issued
  ticket has both, or neither" invariant that a plain `not null` was
  originally (incorrectly) used for. A legacy row with neither column set
  passes the check trivially (`null = null` is `null`, not `false`, so the
  check is satisfied).
- `create extension if not exists pgcrypto;` (defensive/idempotent — a
  real Supabase project already has it installed, typically into an
  `extensions` schema rather than `public`).
- New function `issue_tickets_for_order(p_order_id, p_qr_encryption_key)
returns integer` — the core atomic, idempotent issuance. `service_role`
  only. `set search_path = public, extensions, pg_temp` — `extensions` is
  required here (not just `public`) because `gen_random_bytes`, `digest`,
  and `pgp_sym_encrypt` are real `pgcrypto` functions that live in
  Supabase's `extensions` schema; only `gen_random_uuid()` is a
  core/`pg_catalog` builtin unaffected by this. Missing `extensions` here
  is exactly the bug a real `supabase test db` run caught (see "Validation
  results").
- New function `issue_tickets_for_order_safe(p_order_id,
p_qr_encryption_key) returns void` — the exception-isolating wrapper
  `confirm_order_payment` actually calls. `service_role` only.
- `confirm_order_payment` redefined (`drop function` + `create function`,
  new migration only) to accept an 11th parameter,
  `p_qr_encryption_key text default null` — a trailing **default**
  parameter, not a required one. This is deliberate and load-bearing:
  RFC-007's own 14 historical test call sites, and any other legacy
  10-argument caller, must keep resolving to this same function without
  modification. A required 11th parameter (the first version of this fix)
  changes the function's signature entirely, so PostgreSQL can no longer
  match a 10-argument call to anything (`42883 undefined_function`) — this
  is exactly the second real bug a `supabase test db` run caught (see
  "Validation results"). The function calls
  `issue_tickets_for_order_safe(v_order.id, p_qr_encryption_key)`
  immediately after the order is transitioned to `PAID`, passing `null`
  through untouched when a legacy caller omits the argument (issuance then
  fails fast inside `issue_tickets_for_order` itself and is swallowed by
  the `_safe` wrapper, same as any other issuance failure). Every other
  line of RFC-007's own payment-truth logic is byte-for-byte unchanged.
- New function `get_order_tickets(p_order_id, p_qr_encryption_key) returns
table (...)` — the buyer-facing read boundary. `service_role` only.
  `set search_path = public, extensions, pg_temp` (calls
  `pgp_sym_decrypt`, same `extensions`-schema reasoning as above).
- New function `reconcile_missing_tickets(p_qr_encryption_key) returns
table (order_id, status, tickets_issued)` — `service_role` only. Added
  specifically to close an observability gap `issue_tickets_for_order_safe`
  leaves open by design: that wrapper correctly protects "a payment
  confirmation is never lost to an issuance bug," but on its own leaves
  "a `PAID` order can silently sit at zero tickets forever" unaddressed
  outside of manually grepping `audit_logs`. This function scans for any
  `PAID`/`REFUNDED`/`PARTIALLY_REFUNDED` order whose actual ticket count is
  less than its `order_items` quantity, and retries
  `issue_tickets_for_order` for each one inside its own exception block —
  one bad order can never block another's recovery, and a fully-recovered
  order is simply absent from the next run's result set (no re-processing,
  no duplication). No new infrastructure (no queue, no worker, no Kafka/
  Redis) — plain, additive, callable on demand today and easy to put behind
  a scheduled job later. See "Validation results" and ADR-016's addendum in
  `docs/architecture.md`.

## Environment / secrets

Two new server-only secrets, validated by a new `getTicketServerEnv()` in
`src/lib/env/server.ts` (kept separate from `getPaymentServerEnv`, same
reasoning RFC-007 already documented for keeping payment secrets out of
the per-request `getServerEnv()` — see ADR-015):

- `TICKET_ACCESS_SIGNING_KEY` — HMAC key for the buyer's ticket-access
  capability.
- `QR_ENCRYPTION_KEY` — symmetric key for QR-secret encryption/decryption.

Deliberately two separate secrets, not one reused for both purposes: a
compromise of one must never automatically compromise the other (one
gates "can this browser view this order's tickets page at all," the other
gates "can this specific raw QR secret be decrypted"). Both are documented
in `.env.example` with generation guidance (`openssl rand -base64 48`).
Local dev values were generated and appended to this machine's
`.env.local` for testing (see "Manual QA steps" — you will want to rotate
these before any shared/deployed use).

## API / route surface

No new public Route Handler was added. The buyer-facing surface is a
single Server Component page:

- `GET /tickets/order/[orderId]?token=...` — server-rendered, requires
  both segments (mirrors `/checkout/[orderId]`'s existing convention).
- `GET /api/orders/[orderId]/payment-status` (RFC-007, unchanged route)
  now optionally returns `ticketsUrl` in its existing JSON shape.

This keeps the public surface as small as the brief asked for ("no
endpoints just because the prompt mentions them").

## UI

- `src/app/tickets/order/[orderId]/page.tsx` — mobile-first, shows event
  name/date/venue once, then one `TicketCard` per ticket (own QR image,
  ticket number, status) — never one shared QR for the whole order.
- `src/features/payments/components/payment-status-view.tsx` — gains a
  "Ver mis entradas" button once `status === "PAID"` and a `ticketsUrl` is
  present.
- `src/app/dashboard/[organizationSlug]/events/[eventId]/page.tsx` — gains
  a basic "Issued tickets" table (Ticket / Type / Order (truncated) /
  Status / Created at). Never renders a raw QR token, buyer-access token,
  checkout token, or any payment secret.

## Observability

A `tickets_issued` `audit_logs` row (`{order_id, ticket_count}`) is
written whenever an issuance call actually inserts one or more new
tickets (not on idempotent no-op repeats, to avoid audit-log noise from
routine webhook redeliveries). A `tickets_issuance_failed` row
(`{order_id, sqlstate, message}` — never a secret) is written whenever
`issue_tickets_for_order_safe` catches a failure. Together these directly
answer the two diagnostic questions the brief asked for: "payment approved
but tickets missing" → look for `tickets_issuance_failed` against that
`order_id`; "duplicate issuance attempt" → `issue_tickets_for_order`'s
return value (newly-inserted count) is `0` on every repeat call, and no
new `audit_logs` row is written for it, so the audit trail itself shows
issuance only ever "happened" once per order. No new logging platform was
introduced.

## Testing

`supabase/tests/database/rfc_008_ticketing.test.sql` — 63 pgTAP
assertions (48 original + 15 added after the real-Supabase corrective
round below): function privileges (service_role-only on all four new/
redefined functions, including `reconcile_missing_tickets`),
schema invariants (no plaintext QR column exists), successful issuance
(qty 1→1, qty 5→5, mixed 2+3→5 correctly split across order_items),
ticket field correctness (status, issued_at, checked_in_at,
tenant-correct organization_id/event_id), idempotency (duplicate webhook
delivery, repeated direct issuance calls), payment-state gating
(PENDING_PAYMENT/EXPIRED/PAYMENT_FAILED/nonexistent all rejected, and
`confirm_order_payment` itself never even reaches issuance for a
non-payable order), the exception-isolating wrapper (never raises, records
a diagnosable failure, never leaks the key), QR invariants (every hash
distinct, every ciphertext distinct, hash/ciphertext internally
consistent, wrong-key decryption fails), the buyer read boundary
(`get_order_tickets` returns the right count, the right decrypted token,
rejects unpaid/nonexistent orders with the same error, `anon` cannot call
it or `issue_tickets_for_order` at all), and tenant isolation (Org B sees
zero of Org A's tickets, by both a direct query and by RLS under an
authenticated Org B session), and — the 15 new assertions (49-63) —
regression coverage for the three real-Supabase bugs and their fixes: a
legacy ticket with no `ticket_sequence`/`qr_secret_ciphertext` still
inserts and reads back as `VALID`; every RFC-008-issued ticket has both
columns populated together, never one without the other; the historical
10-argument `confirm_order_payment` call form still resolves and still
reaches `PAID`; a resulting zero-tickets issuance failure is recorded to
`audit_logs`, never silently invisible; and `reconcile_missing_tickets`
detects that exact condition on its own, recovers it, is a safe no-op
once recovered, and is `service_role`-only like every other
issuance-touching function.

`scripts/rfc-008-concurrency-test.sh` — mirrors `rfc-006`/
`rfc-007-concurrency-test.sh`'s existing pattern exactly (same fixture/
teardown structure, same local-only safety guard). Fires many real,
concurrent `psql` connections at `issue_tickets_for_order` for the same
never-yet-issued order and asserts the final ticket count and the count of
distinct `(order_item_id, ticket_sequence)` pairs both equal the order's
quantity, with zero failed calls.

## Validation results

**Real command execution, honestly scoped — and, this round, explicitly
separated into what a substitute Postgres proved versus what an actual
local Supabase stack proved, because the two previously disagreed.**

- `npm run typecheck` — **PASS**, clean, no errors (re-confirmed after
  this round's fixes; no TypeScript files changed).
- `npm run lint` — **PASS**, clean, no errors (re-confirmed).
- `npm run format:check` — **PASS** (re-confirmed; no new formatting
  issues from this round's SQL-only changes).
- `npm run build` — **PASS** (re-confirmed). Real production build; all
  routes compile, including `/tickets/order/[orderId]` correctly
  registered as dynamic (ƒ), not statically prerendered.

**Round 1 — substitute PostgreSQL validation (insufficient on its own).**
Docker was unavailable when this RFC was first implemented, so the
database layer was verified against a disposable native PostgreSQL 16
instance with a minimal `auth.uid()`/`auth.role()` stub, the real `pgtap`
extension installed fresh into `public`, all seven migrations applied in
order, and `rfc_008_ticketing.test.sql` run via `pg_prove`: this reported
**48/48 assertions pass**. That result was real but **misleading**: this
substitute Postgres had never had `pgcrypto` installed before this
migration ran, so `create extension if not exists pgcrypto;` created it
fresh into `public` — exactly where this migration's functions look for
it. A real Supabase project already has `pgcrypto` installed into an
`extensions` schema before any project migration ever runs, so the same
line instead correctly no-ops, and the schema mismatch this masked
(`extensions` vs `public`) went completely undetected.

**What the real `npx supabase test db` run found.** Once Docker became
available and you ran the actual local Supabase stack, three real bugs
surfaced that the substitute above had not caught:

1. `rfc_002_security.test.sql` failed with
   `null value in column "ticket_sequence" violates not-null constraint`
   — this migration's original `not null` on `tickets.ticket_sequence`/
   `qr_secret_ciphertext` broke RFC-002's own pre-existing direct-insert
   fixture. **Fixed**: both columns are now nullable, with a
   `check ((ticket_sequence is null) = (qr_secret_ciphertext is null))`
   constraint carrying the real invariant instead (see "Database
   changes").
2. `rfc_007_payments.test.sql` failed 23/24 of its "insufficient
   privilege" assertions with `42883 undefined_function` instead of the
   expected `42501` — the original `confirm_order_payment` redefinition
   added a REQUIRED 11th parameter, so none of RFC-007's 14 historical
   10-argument call sites resolved to any function at all anymore.
   **Fixed**: the new parameter is now `p_qr_encryption_key text default
null`, a trailing default, so both the legacy 10-argument form and the
   new 11-argument form resolve to the same single function (see
   "Database changes").
3. `rfc_008_ticketing.test.sql` itself failed with
   `function gen_random_bytes(integer) does not exist` inside
   `issue_tickets_for_order`, cascading into 9 failed assertions (all
   expected ticket counts/fields came back 0/null). **Root cause**:
   `gen_random_bytes`/`digest`/`pgp_sym_encrypt` are real `pgcrypto`
   functions living in Supabase's `extensions` schema, unreachable from
   this migration's `set search_path = public, pg_temp` functions (unlike
   `gen_random_uuid()`, a PG13+ core builtin unaffected by schema
   placement). **Fixed**: `extensions` added to the `search_path` of every
   function that calls a `pgcrypto` function directly (see "Database
   changes"). This also exposed a real, separate observability gap:
   `issue_tickets_for_order_safe`'s exception-swallowing correctly kept the
   `PAID` transition intact, but silently left the order at zero tickets
   with no way to detect or recover it outside of manually grepping
   `audit_logs`. **Addressed**: the new `reconcile_missing_tickets`
   function (see "Database changes") — plain, additive, `service_role`-
   only, no new infrastructure.

**Round 2 — a more faithful substitute PostgreSQL validation (still not
the real thing).** To re-verify these three fixes without waiting on
another live Supabase round-trip, a NEW disposable PostgreSQL 16 instance
was built specifically to mirror the real bootstrap order that Round 1's
instance did not: `extensions` schema created and `pgcrypto`/`pgtap`
installed into it BEFORE any migration runs (reproducing the real
"already exists, skipping" no-op this migration's own `create extension`
line hits in production), plus `auth`/`extensions` schema `USAGE` grants
and `alter default privileges` applied before the migrations too (so a
later migration's own `revoke`/`grant` — e.g. RFC-005's column-level
restriction on `organizations` for `anon` — sticks, instead of being
silently re-widened by a blanket grant applied after the fact, which is
what this environment's own earlier setup was doing). Against this
corrected substitute: all seven migrations (RFC-002 through the FIXED
RFC-008) applied cleanly in order, and the FULL historical + RFC-008 test
suite — `rfc_002_security.test.sql` through `rfc_008_ticketing.test.sql`,
**none of RFC-002 through RFC-007's files modified in any way** — passed
completely: **272/272 assertions across all 7 files, `Result: PASS`**
(22+14+20+18+61+74+63). `scripts/rfc-008-concurrency-test.sh` was not
re-run this round (see "Known limitations").

**This is still substitute PostgreSQL validation, not actual local
Supabase validation.** It is materially more faithful than Round 1 (it is
specifically what caught the `extensions`-schema class of bug when
reproduced), but it remains a hand-built approximation, not Supabase's own
Postgres image. **The authoritative check is yours to run**:
`npx supabase db reset && npx supabase test db` against your real local
stack, exactly as before. Expected result, if these fixes are correct:
RFC-002 through RFC-008 all green, RFC-002 22/22, RFC-007 74/74, RFC-008
63/63 or more, overall `Result: PASS`.

- `src/types/database.ts` — regenerated from the verified RFC-008 schema,
  then reconciled by hand against the version already in this repo: the
  substitute generator toolchain (a different `supabase` CLI installation
  than whatever originally produced this file) narrowed the nullability
  of several unrelated, unchanged RFC-006/007 function parameters (e.g.
  `confirm_order_payment`'s `p_payment_method`/`p_approved_at`,
  `create_order_with_hold`'s `p_buyer_phone` — all real, intentional
  `| null` types in the original file, all narrowed to non-null `string`
  by the substitute tool, which would have broken `npm run typecheck`
  for existing, unmodified call sites in `src/features/checkout/api.ts`
  and `src/features/payments/webhook.ts`). Rather than ship that
  regression, the original file was restored and patched by hand with
  only what RFC-008 actually adds (three `tickets` columns, three new
  function entries, one new parameter on `confirm_order_payment`) — the
  same shapes independently confirmed against the real applied schema in
  the verification database. This is a deliberate, narrow exception to
  "always regenerate, never hand-edit," made necessary by the
  Docker-unavailable environment; once you have a real local Supabase
  stack, running the standard `supabase gen types typescript --local`
  command is still the right way to keep this file in sync going forward.

## Files created / modified

**Created:**
`supabase/migrations/20260928000000_rfc_008_ticketing.sql`,
`supabase/tests/database/rfc_008_ticketing.test.sql`,
`scripts/rfc-008-concurrency-test.sh`,
`src/lib/tickets/access-token.ts`, `src/lib/tickets/qr.ts`,
`src/features/tickets/types.ts`, `src/features/tickets/queries.ts`,
`src/features/tickets/components/ticket-card.tsx`,
`src/app/tickets/order/[orderId]/page.tsx`,
`docs/rfcs/RFC-008-ticketing.md` (this file).

**Modified:** `src/lib/env/server.ts` (added `getTicketServerEnv`),
`src/features/payments/webhook.ts` (passes `QR_ENCRYPTION_KEY` into
`confirm_order_payment`), `src/features/payments/types.ts` (added
`ticketsUrl` to `PaymentStatusResponse`), `src/features/payments/queries.ts`
(computes `ticketsUrl`), `src/features/payments/components/payment-status-view.tsx`
(renders the CTA), `src/app/payment/result/page.tsx` (threads
`initialTicketsUrl` through), `src/app/dashboard/[organizationSlug]/events/[eventId]/page.tsx`
(added "Issued tickets" section), `src/types/database.ts` (see
"Validation results" above), `package.json`/`package-lock.json` (added
`qrcode`/`@types/qrcode`), `.env.example` (documented the two new
secrets), `docs/architecture.md` (ADR-016/017/018).

## Known limitations / assumptions

- No key-rotation flow exists for `QR_ENCRYPTION_KEY` — rotating it makes
  every previously-issued ticket's QR permanently undecryptable for
  redisplay (the `qr_token_hash` used for RFC-009 scanning is unaffected,
  since it never depends on the encryption key). `qr_secret_version` exists
  specifically so a future rotation scheme has somewhere to record which
  scheme a given row uses.
- `pgp_sym_encrypt` is not an AEAD cipher — accepted deliberately, see
  ADR-017 for the full reasoning; revisit if the threat model ever
  requires decrypting untrusted/attacker-supplied ciphertext (it doesn't
  today).
- `TICKET_ACCESS_SIGNING_KEY`/`QR_ENCRYPTION_KEY` have no rotation UI;
  rotating either is a manual env-var change plus (for the QR key) an
  understanding that old tickets' redisplay breaks.
- `reconcile_missing_tickets` has no scheduler or automatic trigger —
  it is callable on demand (e.g. from a `service_role` admin script or a
  future cron/Edge Function) but nothing invokes it automatically today.
  For MVP this is an accepted gap: the important property is that
  recovery is _possible and safe_, not yet that it is _automatic_. Wiring
  it to a schedule is a natural, low-risk follow-up once there is real
  operational signal for how often issuance actually fails in production.
- `scripts/rfc-008-concurrency-test.sh` was not re-run against this
  round's fixes (schema/signature/search_path changes only — its own
  concurrency logic and the unique-constraint mechanism it exercises are
  unchanged) — re-run it against your real local stack alongside
  `supabase test db` for full confidence.
- The corrected migration and tests have been verified against a
  substitute PostgreSQL instance built to mirror Supabase's `extensions`-
  schema and default-privilege bootstrap order (see "Validation results"),
  but **not yet against your actual local Supabase stack** — that is the
  validation you should run yourself before trusting this beyond what's
  documented here: `npx supabase db reset && npx supabase test db`.
- The admin "Issued Tickets" view is intentionally basic (no pagination,
  no filtering) — fine for MVP scale, not built for a large venue's ticket
  volume.
- No email delivery of tickets — the buyer's only path to their tickets is
  the link surfaced on `/payment/result`; if they navigate away before
  it appears (or before polling reaches `PAID`), they need it re-derived
  by some other means in a future RFC (e.g. resending the link by email,
  out of RFC-008's scope).

## Manual QA steps

1. Create and publish an event with at least one public ticket type.
2. Buy N tickets (try both a single ticket type at quantity > 1, and a
   mixed cart across two ticket types) through the normal checkout flow.
3. Complete payment with Mercado Pago TEST credentials (a genuine Test
   Buyer account, same country as the seller — see RFC-007's doc for the
   exact sandbox setup, unchanged by this RFC).
4. Confirm the webhook fires and the order reaches `PAID` (same as RFC-007
   QA).
5. On `/payment/result`, confirm a "Ver mis entradas" button appears once
   status is confirmed `PAID`.
6. Click it; confirm the tickets page shows exactly N tickets, each with
   its own distinct QR code image, correct ticket type name, and `VALID`
   status.
7. Refresh the tickets page: confirm the same N tickets/QR codes appear
   (nothing regenerates).
8. Copy the tickets-page URL, close the tab, reopen it fresh (simulating
   the buyer returning later): confirm it still works and shows the same
   tickets.
9. Manually resend the exact same webhook notification (or wait for
   Mercado Pago's own retry): confirm the ticket count does NOT change.
10. Try the tickets URL with the token altered/removed: confirm it 404s
    (not an error page, not a partial reveal).
11. In the dashboard, open the event and confirm the "Issued tickets"
    table lists all N tickets with correct type/status, and never displays
    a raw QR value.

## Decisions needed before RFC-009

- **QR content format is frozen as `lt:v1:<rawToken>`** — RFC-009's
  scanner should split on `:`, check the `lt`/`v1` prefix, then
  `sha256`-hash the remainder and look it up against
  `tickets.qr_token_hash`. Confirm this is workable for whatever scanning
  library/approach RFC-009 chooses before building against it.
- **Check-in itself is entirely unimplemented** — RFC-009 will need its
  own atomic "mark checked-in" function (this RFC deliberately left
  `check_ins`/the check-in transition untouched, per Non-goals).
- **Key rotation strategy for `QR_ENCRYPTION_KEY`** is an open question if
  key rotation becomes a real operational need before a more thorough
  KMS-backed redesign is justified.
