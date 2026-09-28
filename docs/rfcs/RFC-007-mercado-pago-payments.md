# RFC-007 — Mercado Pago Checkout Pro & Payment Processing

## Status

Implemented and locally verified to the extent this environment allows
(see "Validation results" and "Known limitations" for exactly what
"verified" means here — no local Supabase/Docker stack was reachable in
either the cloud sandbox or the Mac's bridged Cowork VM). **Not
committed, not pushed to Supabase Cloud, no production Mercado Pago
credentials configured** — this document describes the local
implementation pending review, per the RFC's own final instruction.

## Problem

RFC-006 gave Lucky Ticket a real, concurrency-safe checkout: an anonymous
buyer can select tickets, and the platform atomically creates a
`PENDING_PAYMENT` order with a genuine inventory hold. Nothing after that
point exists yet — there is no way to actually pay, and no way for
Lucky Ticket to ever know a payment happened. RFC-007 closes that gap:
`PENDING_PAYMENT` order → Mercado Pago Checkout Pro preference → buyer
redirected to Mercado Pago → buyer pays → Mercado Pago's webhook →
Lucky Ticket independently verifies the payment with Mercado Pago's own
API → order atomically becomes `PAID`.

The central discipline of this RFC, restated because it governs every
design decision below: **an order must never become `PAID` because the
browser says so.** The redirect back from Mercado Pago is presentation
only. Only a webhook that Lucky Ticket has authenticated, followed by an
independent server-to-server fetch of the payment resource from Mercado
Pago's own API, may transition an order to `PAID`.

## Goals

- A buyer on `/checkout/[orderId]?token=...` can press "Continuar al
  pago" and land on Mercado Pago's hosted Checkout Pro page for exactly
  their order's authoritative items/total — never a browser-supplied
  price.
- After paying (or abandoning/failing), the buyer returns to a Lucky
  Ticket page that shows their order's real status, polling briefly if
  the webhook hasn't landed yet, and never claims success until Lucky
  Ticket has independently confirmed it.
- Mercado Pago's webhook is the only path to `PAID`: authenticated via
  signature verification, backed by an independent fetch of the payment
  resource from Mercado Pago's API, validated against the order's
  authoritative amount/currency/identity, and applied atomically.
- The same webhook notification, delivered any number of times
  (Mercado Pago's own retry schedule, or an accidental duplicate),
  produces exactly one logical effect.
- A hold that expires around the moment a genuine payment is approved is
  handled correctly in both directions: a late-but-real payment is
  honored when capacity remains, and inventory is never oversold when it
  doesn't.
- Payment credentials never reach the browser, under any code path.

## Scope

Mercado Pago Checkout Pro preference creation, the Mercado Pago webhook
endpoint and its authenticity/authoritative-verification pipeline, the
atomic `PENDING_PAYMENT → PAID` transition, a public payment-status read
endpoint, the buyer-facing result/polling page, and the minimal payment
gateway abstraction and schema additions needed to support all of this.

## Non-goals

This RFC explicitly does **not** implement: ticket issuance, QR
generation, QR scanning, ticket emails, Resend, check-in, refunds,
chargebacks workflow, organizer settlements, Lucky Ticket invoicing,
platform fee collection, Mercado Pago Marketplace OAuth, split payments,
application fees, promo codes, discount campaigns, promoters, resale,
ticket transfer, seat maps, merchandising, or native apps. All of these
are explicitly out of scope; ticket issuance in particular is RFC-008's
job, starting from `order.status = 'PAID'`.

## Mercado Pago documentation consulted

Implemented against currently-live official Mercado Pago Developers
pages (fetched during this work, not from training memory), plus direct
inspection of the installed `mercadopago` npm SDK's own TypeScript
definitions (a stronger check than documentation prose for exact field
names):

- Checkout Pro — webhooks / notifications:
  `mercadopago.com.ar/developers/en/docs/checkout-pro/additional-content/notifications/webhooks`
  — `x-signature` header format (`ts=...,v1=...`), the 22-second
  acknowledgement window, and the retry schedule ("retry sending every
  15 minutes... after the third attempt the interval will be
  extended").
- Signature manifest construction (confirmed via the QR-code
  notifications page, which documents the same shared webhook
  mechanism): `mercadopago.com.br/developers/pt/docs/qr-code/notifications` —
  the exact manifest template `id:{data.id};request-id:{x-request-id};ts:{ts};`,
  the rule that `data.id` is lowercased before inclusion, and the rule
  that a missing `data.id` or `x-request-id` is **removed from the
  manifest entirely**, not left blank.
- Payment status values for the classic Payments resource (`GET
/v1/payments/:id`, what Checkout Pro produces — deliberately **not**
  the newer, differently-shaped Orders API):
  `mercadopago.com.ar/developers/en/docs/checkout-api-payments/response-handling/query-results`
  — confirms the exact status set `approved / authorized / in_process /
pending / cancelled / charged_back / in_mediation / refunded /
rejected` used by `src/lib/mercado-pago/mapper.ts`.
- `mercadopago` npm package (`sdk-nodejs`) — inspected the actually
  installed version's `.d.ts` files directly
  (`node_modules/mercadopago/dist/clients/**/*.d.ts`) for `Preference`,
  `Payment`, `Items`, `BackUrls`, `Payer` field shapes, and
  `MercadoPagoConfig`'s constructor options — stronger verification than
  documentation prose for exact request/response field names.
- `mercadopago/sdk-nodejs` GitHub issue #481 ("idempotencyKey leaks into
  every later call when `MercadoPagoConfig` is shared") — informed the
  decision in `src/lib/mercado-pago/client.ts` to construct a brand-new
  `MercadoPagoConfig` per call rather than a shared module-level
  instance, which this bug does not affect since nothing is shared.

Provider-specific decisions this drove: Checkout Pro (hosted redirect),
never Checkout Bricks or the raw Card API — no card data is ever
collected or transmitted through Lucky Ticket's own servers. The
**classic** Payments resource is authoritative (`GET /v1/payments/:id`,
returned by `Payment.get()`), not the newer Orders API — a genuinely
different resource shape with different status names entirely (a search
result during this work briefly surfaced the Orders API's `processed` /
`action_required` / `expired` vocabulary, which does **not** apply to
Checkout Pro's classic payment flow, and was consciously rejected).

## Inspecting existing architecture first

Before writing any code: the full RFC-002 schema and RLS
(`orders`, `order_items`, `ticket_holds`, `payments`, `payment_accounts`,
`webhook_events`, `customers`, `audit_logs`), the full RFC-006 migration
(`create_order_with_hold`, `get_checkout_order`,
`get_public_ticket_availability`, `expire_pending_orders`, and the
inventory-formula precedent this RFC deliberately reuses unchanged), the
checkout feature code (`src/features/checkout/*`), `src/lib/checkout/token.ts`
(the secure checkout-token pattern this RFC extends across the Mercado
Pago redirect), `src/lib/supabase/{public,server}.ts`, `src/lib/env/server.ts`,
and `docs/architecture.md`'s existing ADRs. Conclusion: RFC-002 already
has every table this RFC needs (`payments` already has
`UNIQUE(provider, provider_payment_id)`; `webhook_events` already has
`UNIQUE(provider, provider_event_id)` and a `RECEIVED/PROCESSED/FAILED/IGNORED`
status enum; `payment_accounts` is genuinely credential-free connection
metadata). Nothing here needed redesigning — only two nullable columns
on `orders` were missing (see "Database changes").

## Multi-tenant payment architecture / MVP payment-account strategy

Long-term, an organizer should receive funds directly into their **own**
Mercado Pago account — Lucky Ticket should never become custodian of
event proceeds. RFC-002's `payment_accounts` table (provider +
`provider_account_id` + status, no credential column at all) already
models "which provider account an organization uses" for exactly that
future. Building the full OAuth marketplace onboarding flow (Mercado
Pago Connect / split payments) is explicitly out of scope for RFC-007
("do not prematurely build a full OAuth marketplace onboarding flow
unless required").

**What RFC-007 actually does (the documented MVP/development
limitation):** every Checkout Pro preference is created using a single,
platform-wide `MERCADO_PAGO_ACCESS_TOKEN` (one Mercado Pago account,
configured via environment variable — see "Credential strategy"). This
means, as implemented today, **all organizers' sales settle into that
one Mercado Pago account**, not into each organizer's own account. This
is explicitly called out here (and in `.env.example`'s inline comments)
as a development/MVP limitation, not a solved problem — RFC-007 does not
pretend otherwise. `payment_accounts` is left untouched by this RFC
(no rows are written to it, no code reads it) precisely so that a future
RFC can extend `MercadoPagoPaymentGateway.createCheckout` to resolve a
per-organization access token from `payment_accounts` (once a secure,
server-only credential-storage mechanism for it exists) without needing
to change the `PaymentGateway` interface, the webhook pipeline, or
`confirm_order_payment`'s reconciliation logic at all — the abstraction
boundary was deliberately drawn at "one gateway, given an order, returns
a checkout" rather than "one gateway, hard-coded to one token."

## Checkout Pro architecture

```
Buyer                    Lucky Ticket (Next.js)              Mercado Pago
  |                              |                                 |
  | GET /checkout/[id]?token=.. |                                 |
  |----------------------------->|                                |
  |  (renders order summary +   |                                 |
  |   "Continuar al pago")      |                                 |
  |                              |                                 |
  | click "Continuar al pago"   |                                 |
  |----------------------------->|                                |
  |  POST /api/payments/         |                                |
  |    mercado-pago/preference   |                                |
  |    { orderId, checkoutToken }|                                |
  |                              | 1. verify token (get_checkout_ |
  |                              |    order, RFC-006's boundary)  |
  |                              | 2. verify PENDING_PAYMENT,      |
  |                              |    not expired                 |
  |                              | 3. reuse existing preference     |
  |                              |    if one is already valid      |
  |                              | 4. else: build items/total from |
  |                              |    order_items/orders (never    |
  |                              |    the browser)                |
  |                              |------------------------------->|
  |                              |   POST /checkout/preferences    |
  |                              |   (idempotency key = order id)  |
  |                              |<-------------------------------|
  |                              |   { id, init_point }            |
  |                              | 5. record_payment_preference()  |
  |                              |    persists provider_preference_|
  |                              |    id/checkout_url on the order |
  |<-----------------------------|                                |
  |   { checkoutUrl }            |                                |
  | browser navigates to         |                                |
  | checkoutUrl                  |                                |
  |-------------------------------------------------------------->|
  |                    (buyer pays on Mercado Pago's own page)     |
  |<--------------------------------------------------------------|
  | redirected to back_url =                                      |
  | /payment/result?orderId=..&token=..                            |
```

## Webhook processing (the authoritative path)

```
Mercado Pago                    Lucky Ticket (Next.js)
     |                                  |
     | POST /api/webhooks/mercado-pago |
     |   x-signature: ts=..,v1=..       |
     |   x-request-id: ..               |
     |   body: { type, data: {id} }     |
     |--------------------------------->|
     |                    1. verify signature (HMAC-SHA256 over
     |                       "id:{data.id};request-id:{x-request-id};ts:{ts};",
     |                       missing fields OMITTED entirely).
     |                       Invalid/missing -> 401, NOTHING written.
     |                    2. type !== "payment" -> record_webhook_event()
     |                       (IGNORED), return 200.
     |                    3. record_webhook_event(provider, provider_event_id)
     |                       -> idempotent insert (unique constraint).
     |                       already PROCESSED -> return 200, stop.
     |                    4. fetch the payment from MERCADO PAGO'S OWN API
     |                       (GET /v1/payments/:id) - the webhook body's
     |                       fields are NEVER trusted for truth.
     |<---------------------------------|
     |   GET /v1/payments/{data.id}     |
     |--------------------------------->|
     |   { status, transaction_amount,  |
     |     currency_id, external_       |
     |     reference, ... }             |
     |<---------------------------------|
     |                    5. confirm_order_payment(...) - ONE atomic
     |                       DB transaction: lock order, idempotency
     |                       check, insert payment, validate state/
     |                       currency/amount, transition to PAID (or
     |                       reject with a stable outcome).
     |                    6. mark_webhook_event() PROCESSED/FAILED.
     |   200 OK                         |
     |<---------------------------------|
```

## Redirect / result-page polling

```
Buyer's browser                Lucky Ticket                 Mercado Pago (async)
      |                             |                              |
      | GET /payment/result?        |                              |
      |   orderId=..&token=..       |                              |
      |----------------------------->|                             |
      |  renders "Estamos           |                             |
      |  verificando tu pago..."    |                             |
      |  (server-rendered initial   |                             |
      |   status from                |                             |
      |   getPaymentStatus)          |                             |
      |<-----------------------------|                             |
      |  client polls GET /api/     |                             |
      |  orders/[id]/payment-status  |                              |
      |  every 2s, up to 30 tries    |                              |
      |----------------------------->|                              |
      |                              |     <--- webhook lands, ---> |
      |                              |          confirm_order_       |
      |                              |          payment() runs      |
      |  { status: "PAID" }          |                              |
      |<-----------------------------|                              |
      |  renders "Pago confirmado"   |                              |
      |  and stops polling            |                              |
```

## Payment gateway abstraction

`src/services/payment-gateway/payment-gateway.ts` defines a
provider-agnostic `PaymentGateway` interface:

```ts
interface PaymentGateway {
  createCheckout(input: CreateCheckoutInput): Promise<CheckoutPreference>;
  getPayment(providerPaymentId: string): Promise<ProviderPayment>;
}
```

`src/services/payment-gateway/mercado-pago-payment-gateway.ts` is the
only file that knows about Mercado Pago's request/response shapes
(`Items`, `BackUrls`, `PreferenceResponse`, the raw `Payment` resource).
Everything above the gateway (`src/features/payments/api.ts`,
`webhook.ts`) talks only to the narrow `PaymentGateway` interface and
Lucky Ticket's own domain types (`CheckoutLineItemInput`,
`ProviderPayment`). Swapping providers later — or resolving a
per-organization gateway from `payment_accounts` — changes exactly one
call site (`getPaymentGateway()` in `src/features/payments/api.ts` and
`src/features/payments/webhook.ts`), never any caller. No second
provider is speculatively supported; the interface is shaped by what
Checkout Pro actually needs, not by a hypothetical future provider.

`src/lib/mercado-pago/` holds the three pure/provider-specific pieces
that don't belong inside the gateway class itself: `client.ts` (SDK
config/client construction), `signature.ts` (webhook signature
verification — pure functions, no I/O), and `mapper.ts` (provider status
→ internal `PaymentStatus` mapping, and the float-major-units →
integer-minor-units conversion boundary).

## Credential strategy

Four new environment variables, all validated by a **separate** Zod
schema (`paymentServerEnvSchema` / `getPaymentServerEnv()` in
`src/lib/env/server.ts`), deliberately **not** merged into the existing
`serverEnvSchema` / `getServerEnv()`:

- `MERCADO_PAGO_ACCESS_TOKEN` — server-only. Never read by any client
  component; only imported by `src/lib/mercado-pago/client.ts` (itself
  only imported by the payment gateway, itself only imported by
  server-only route handlers/`src/features/payments/*`).
- `MERCADO_PAGO_WEBHOOK_SECRET` — server-only, used only inside
  `src/lib/mercado-pago/signature.ts`'s `verifyWebhookSignature`.
- `NEXT_PUBLIC_APP_URL` — the one exception that is genuinely public (it
  is, by definition, the base URL used to build redirect URLs the buyer's
  browser navigates to) — used to construct `back_urls`/`notification_url`
  from trusted server-side configuration, never from any
  request-supplied `Host` header or browser input (this is also the
  "no open redirects" control — see "Redirect security").
- `SUPABASE_SERVICE_ROLE_KEY` — server-only, used only by
  `src/lib/supabase/service-role.ts`, itself only imported by webhook
  processing code.

**Why a separate schema matters:** `getServerEnv()`/`isServerEnvConfigured()`
are called by `src/proxy.ts` on **every request** (its own doc comment
says so) to decide whether to attempt a Supabase session refresh. Merging
the four new variables into that schema would mean any environment
missing a Mercado Pago credential — including one that never touches
payments, e.g. local development for the public event page or the
organizer dashboard — would fail on every single request. This was
caught and fixed during implementation (see "Assumptions" for the
original mistake). `getPaymentServerEnv()` is instead called lazily,
only from the specific payment/webhook code paths that need it, and
`npm run build` never needs a real Mercado Pago credential to succeed.

`.env.example` documents all four variables with inline comments,
including the single-platform-account MVP limitation. `.env.local` was
**not** modified with real credentials (RFC-007's explicit instruction).
No secret value has been printed to any terminal output, log, or this
document.

## Preference creation

`POST /api/payments/mercado-pago/preference`, body `{orderId,
checkoutToken}` — nothing else is ever read from the request body.
`src/features/payments/api.ts#createPaymentPreference` orchestrates:

1. Hash the raw checkout token (`hashCheckoutToken`, RFC-006's existing
   function) and call `get_checkout_order(orderId, tokenHash)` — the
   exact same narrow, token-authorized read boundary RFC-006 already
   established. An invalid/missing token or nonexistent order raises
   `INVALID_CHECKOUT_TOKEN`.
2. Reject unless `order_status === 'PENDING_PAYMENT'` (this also rejects
   an order `get_checkout_order` is already virtually reporting
   `EXPIRED`, since that derivation happens inside the same function).
3. **Preference reuse** (RFC-007's "multiple preference requests"
   requirement): if `provider_preference_id` and `provider_checkout_url`
   are already set on the order, return the existing `checkoutUrl`
   immediately — no second Mercado Pago API call, no second
   `record_payment_preference` write. This makes a double-click, a
   page refresh, or a retried POST all safe and cheap.
4. Otherwise, build `items` **only** from `get_checkout_order`'s own
   `items` (which itself derives from `order_items`, populated
   exclusively by RFC-006's `create_order_with_hold` from
   `ticket_types` — the browser is never in this chain at all), each
   carrying `id: ticketTypeId` (Mercado Pago's `Items.id` is a required
   field per the installed SDK's types — the order's own ticket type id
   is a safe, non-secret, already-authoritative value for it), `title`,
   `quantity`, and `unitPriceMinor` converted to Mercado Pago's expected
   major-unit float only inside the gateway.
5. `external_reference = orderId` — the sole correlation mechanism
   webhook processing later uses to map a payment back to a Lucky
   Ticket order.
6. `metadata = {order_id, organization_id, event_id}` — minimal
   reconciliation hints only, never the checkout token, never any
   secret, never unnecessary PII.
7. `back_urls.success/pending/failure` all point at the **same** shared
   result route (see "Return routes"), built from `NEXT_PUBLIC_APP_URL`
   (never a request header).
8. `notification_url = ${NEXT_PUBLIC_APP_URL}/api/webhooks/mercado-pago`.
9. Idempotency key on the **creation** call itself:
   `lucky-ticket-preference:${orderId}`, passed via
   `MercadoPagoConfig({options: {idempotencyKey}})` — a stable key
   derived from the order's own identity, so if Lucky Ticket's own
   request to Mercado Pago times out and is retried, Mercado Pago itself
   treats it as the same creation attempt rather than minting a second
   preference server-side, as a second layer beneath the DB-level
   preference-reuse check in step 3.
10. `record_payment_preference(orderId, tokenHash, provider,
preferenceId, checkoutUrl)` persists the result — re-verifying the
    token and payability itself, never trusting that the route handler
    already checked (RFC-006's own SECURITY DEFINER convention).
11. Return `{checkoutUrl}` — the buyer's browser navigates there
    directly; no price, total, or status field is ever sent back that
    the browser could misuse.

Expired-order handling (step 2) means an already-expired order can never
get a **new** preference minted for it — the buyer is told to return and
select tickets again (surfaced by `ORDER_NOT_PAYABLE` /
`PaymentError`).

## Webhook signature verification

Exact algorithm implemented in `src/lib/mercado-pago/signature.ts`,
matching the currently-live Mercado Pago documentation (see "Mercado
Pago documentation consulted"):

1. Parse the `x-signature` header: comma-separated `key=value` pairs,
   extract `ts` and `v1`. Missing either → invalid, immediately.
2. Build the manifest string:
   `id:{data.id, lowercased};request-id:{x-request-id};ts:{ts};` — with
   the critical nuance that **an absent `data.id` or `x-request-id`
   removes that entire segment from the manifest**, it is never left as
   an empty `id:;`.
3. `HMAC-SHA256(manifest, MERCADO_PAGO_WEBHOOK_SECRET)`, hex-encoded.
4. Compare against `v1` using `crypto.timingSafeEqual` (constant-time),
   with an explicit length-equality guard first (mismatched lengths
   would otherwise make `timingSafeEqual` throw rather than return
   `false` — handled so a malformed `v1` is just "invalid", never a
   500).

An invalid, missing, or malformed signature returns HTTP 401
**immediately, before any database write** — this is deliberate: writing
to `webhook_events` first (keyed by an attacker-controlled `data.id`)
would let an unauthenticated request pre-empt a legitimate future
delivery via the `ON CONFLICT DO NOTHING` idempotency path, silently
reporting it as "already seen." Signature verification is strictly
ordered before any database interaction.

## Provider verification

After signature verification passes, `src/features/payments/webhook.ts`
never trusts the webhook **body** for payment truth — it extracts only
the resource id (`data.id`) and calls
`MercadoPagoPaymentGateway.getPayment(dataId)`, which calls the real
`GET /v1/payments/:id` via the SDK's `Payment.get()`. The fields treated
as authoritative from that response, and **only** from that response,
never from the webhook body: `status`, `transaction_amount`,
`currency_id`, `external_reference`, `payment_method_id`,
`date_approved`. If the fetch itself fails (Mercado Pago unreachable,
transient error), the webhook returns 502 so Mercado Pago's own retry
schedule tries again later — the notification is marked `FAILED`, not
silently dropped.

## Payment reconciliation invariants

Centralized entirely inside `confirm_order_payment` (never scattered
across route handlers), checked in this order, each with a distinct
outcome:

1. Idempotency fast path: a payment already recorded for
   `(provider, provider_payment_id)` → `ALREADY_PROCESSED`, no matter
   what else changed.
2. `p_status <> 'APPROVED'` → `RECORDED_NOT_APPROVED` (payment attempt
   recorded, order untouched, still retryable).
3. Order already `PAID` (a second distinct approved payment for the same
   order) → `ORDER_ALREADY_PAID`, audit-logged, order untouched.
4. Order not in `PENDING_PAYMENT`/`EXPIRED` (e.g. `CANCELLED`) →
   `REJECTED_ORDER_STATE`.
5. `p_currency <> orders.currency` → `REJECTED_CURRENCY_MISMATCH`.
6. `p_paid_amount_minor <> orders.total_amount` → `REJECTED_AMOUNT_MISMATCH`
   (integer minor-unit comparison — see "Amount/currency conversion
   boundary" below, never floating point).
7. If the order's normal payable window has already elapsed (status
   still `PENDING_PAYMENT` but past `expires_at`, or already virtually
   `EXPIRED`): re-verify capacity for every line, excluding this order's
   own now-irrelevant hold, under a fresh lock — see "Expiration race."
   Only if capacity still holds → `PAID_LATE_RECOVERY`; otherwise →
   `REJECTED_INVENTORY_UNAVAILABLE` (payment still recorded, order
   untouched, audit-logged for manual reconciliation).
8. Otherwise → `PAID` (paid_at stamped).

`external_reference` (`= orders.id`) is the sole order-identity
correlation; provider payment id → exactly one `payments` row (DB unique
constraint); order → exactly one organization (both live on the same
row via `orders.organization_id`, copied onto `payments.organization_id`
at insert time). Every rejection path still writes a `payments` row
(full audit trail — nothing is silently discarded) and an `audit_logs`
row for observability.

## Amount/currency conversion boundary

Mercado Pago's `transaction_amount` is a JSON **float in major units**
(e.g. `1500.5`). `src/lib/mercado-pago/mapper.ts#providerAmountToMinorUnits`
converts via `Math.round(Number(amount.toFixed(2)) * 100)` — never a
naive `amount * 100` (which can silently misround on binary-float
inputs like `19.99`), and the comparison against `orders.total_amount`
inside `confirm_order_payment` is an integer `bigint` equality check in
Postgres, never a floating-point comparison anywhere in the pipeline.
This conversion happens in exactly one place; nothing downstream ever
touches a raw provider float again.

## Idempotency

Two independent layers, at two independent points:

- **Preference creation**: a stable idempotency key
  (`lucky-ticket-preference:${orderId}`) passed to Mercado Pago on
  creation, plus the DB-level preference-reuse check in
  `createPaymentPreference` (step 3 above) — belt and suspenders against
  double-clicks/retries before a payment ever exists.
- **Webhook/payment confirmation**: `record_webhook_event`'s `ON
CONFLICT (provider, provider_event_id) DO NOTHING` (RFC-002's existing
  unique constraint) makes redelivery of the same notification a no-op
  at the row level; `confirm_order_payment`'s own idempotency check on
  `(provider, provider_payment_id)` — backed by RFC-002's
  `payments_provider_payment_key` unique constraint and an explicit
  `exception when unique_violation` catch block — is what actually
  guarantees **at the database level** that concurrent duplicate
  deliveries can never both succeed: whichever call's `INSERT` loses the
  race gets `unique_violation`, catches it, and returns the winner's
  existing `payment_id` as `ALREADY_PROCESSED`. Application-level
  check-then-insert alone (the `SELECT` before the `INSERT`) is only the
  fast path — the constraint is the actual backstop under concurrency.

## Transaction boundaries

Exactly one thing happens atomically, inside `confirm_order_payment`,
under a single Postgres transaction (the function's own implicit
transaction as called from a single RPC): `SELECT ... FOR UPDATE` locks
the order row first (the single serialization point for every concurrent
caller touching this order); the idempotency check, the `payments`
insert, every validation branch, the late-recovery inventory
re-verification (which itself locks every affected `ticket_types` row,
ascending id order — same deadlock-avoidance convention as RFC-006's
`create_order_with_hold`), the `orders.status = 'PAID'` update, and the
`audit_logs` insert all happen inside that one function invocation —
either the whole thing commits, or (on any raised exception) the whole
thing rolls back. There is no code path that updates `orders.status`
without also having just inserted/confirmed the corresponding `payments`
row in the same transaction. Webhook bookkeeping
(`record_webhook_event`/`mark_webhook_event`) is deliberately **not**
folded into the same transaction as `confirm_order_payment` — receipt of
a webhook is recorded durably even if a later step fails, on purpose
(observability over strict atomicity for that one narrow case), except
that `confirm_order_payment` itself does mark the webhook `PROCESSED`
inline when it succeeds, so the common path never needs a second
round-trip.

## Order state machine / retry behavior

`PENDING_PAYMENT → (approved, verified) → PAID`,
`PENDING_PAYMENT → (expire_pending_orders sweep) → EXPIRED`. There is
**no** `PENDING_PAYMENT → PAYMENT_FAILED` transition in this RFC: a
single rejected/pending payment **attempt** is recorded as a `payments`
row with the appropriate status, but the **order** stays
`PENDING_PAYMENT` as long as its hold is still active — the buyer can
simply try paying again against the same order (a fresh Mercado Pago
attempt, a new `provider_payment_id`, same order id). This is a
deliberate distinction between payment-**attempt** state (tracked per-row
in `payments`, unbounded — many attempts can exist per order) and
order-**lifecycle** state (one column, coarse, and only ever advanced
forward by `confirm_order_payment` or `expire_pending_orders`).
`PAYMENT_FAILED` (the enum value already existed in RFC-002) is reserved
for a future RFC that might want to represent "this order's hold is gone
and it will never be retried" as a distinct terminal state from
`EXPIRED` — RFC-007 does not need or use it, since "the hold expired" is
already `EXPIRED` and a rejected attempt while the hold is still active
is simply retryable `PENDING_PAYMENT`.

## Expiration race

The explicitly-flagged critical edge case: a hold's `expires_at` passes
around the same moment a genuinely approved payment arrives (buyer paid
just before an 8-minute countdown hit zero; the webhook lands a few
seconds after). Two failure modes must both be avoided: silently failing
a genuinely successful payment, and overselling.

**Resolution** (`confirm_order_payment`, step 7 above): if the order's
normal payable window has already lapsed, the function does **not**
immediately reject. It re-derives current availability for every line on
the order — the exact same formula RFC-006's `get_public_ticket_availability`
and `create_order_with_hold` already use (`quantity - SUM(committed
PAID order_items) - SUM(still-active PENDING_PAYMENT holds)`), this time
explicitly **excluding the order's own hold** (`o3.id <> v_order.id`),
under a fresh `FOR UPDATE` lock on each affected `ticket_types` row
(ascending id order, preventing a race with a concurrent new checkout
for the same ticket type). Only if every line still fits does the late
`PAID_LATE_RECOVERY` transition proceed; otherwise the payment is fully
recorded (nothing lost) but the order is left as-is, returning
`REJECTED_INVENTORY_UNAVAILABLE` for manual reconciliation. "Do not
oversell" always wins over "the payment arrived late," but a late,
genuine payment against still-available capacity is never punished for
arriving late. Both directions are exercised by the pgTAP suite
(sections H1/H2 — tests 56/57 and 59-62).

**Reconciliation edge case worth naming**: `REJECTED_INVENTORY_UNAVAILABLE`
means Lucky Ticket has taken a buyer's money (Mercado Pago shows the
payment as approved) without giving them a ticket, because someone else
legitimately claimed the capacity in the meantime. This RFC does not
implement automated reconciliation/refund tooling for that case — it is
recorded (payment row + `audit_logs` entry) for a human to handle
manually, which is an explicit, accepted known limitation (see "Known
limitations"), not a scenario this RFC pretends to fully close.

## Inventory (no double-counting)

No explicit "release the hold" step exists, and none was added. RFC-006's
inventory formula already stops counting a hold the instant its order's
`status` leaves `'PENDING_PAYMENT'` (every "held" query filters
`o.status = 'PENDING_PAYMENT'`), and starts counting the same quantity
via `order_items` the instant `status` becomes `'PAID'` (every
"committed" query filters `o.status = 'PAID'`). Both formulas key off
the **same** `orders.status` column. This means the single
`UPDATE orders SET status = 'PAID'` inside `confirm_order_payment` is
simultaneously "remove this order's hold from the held bucket" and "add
this order's items to the committed bucket" — there is no window, however
small, where the quantity is counted twice or not at all, because there
is no intermediate state between the two buckets at all; it is one
column read by two different `WHERE` clauses. The `ticket_holds` row
itself is never deleted (a full historical record), it simply stops
being counted. This is directly proven, not just asserted, by pgTAP
Section G (tests 51-55): a ticket type with exactly 2 units, 2 pending
holds consuming both, confirming one to `PAID`, and asserting
availability is **still exactly 0** afterward — not `-1` (which double-
counting would produce) and not `1` (which "hold wrongly still counted"
would produce).

## RLS / security

No RLS policy was added, removed, or weakened by this RFC. `payments`
and `webhook_events` keep RFC-002's existing posture unchanged: `anon`
and `authenticated` have zero table-level access to either (mediated
entirely through the SECURITY DEFINER functions below); `payments` is
additionally readable by an organization's `OWNER`/`ADMIN` via RFC-002's
existing `payments_select_admin` policy (unchanged, reused, verified by
pgTAP Section K); `webhook_events` has zero client-role policies at all
(service-role only, since it has no organization scoping and may contain
provider data not meant for any tenant). `orders` keeps its existing
`orders_select_operator` policy and, critically, **still has no
client-facing UPDATE policy of any kind** — this is what makes "the
browser cannot mark PAID" a database-enforced fact rather than an
application convention (pgTAP Section J, tests 70-72, directly exercises
this: a raw `UPDATE orders SET status = 'PAID'` as both `anon` and an
owning organization's `authenticated` `OWNER` leaves the row unchanged).

Four new/redefined functions, following RFC-003's explicit-revoke-then-grant
precedent (`revoke all ... from public/anon/authenticated`, then grant
only the intended role — never relying on default privileges):

| Function                         | anon    | authenticated | service_role |
| -------------------------------- | ------- | ------------- | ------------ |
| `get_checkout_order` (redefined) | EXECUTE | EXECUTE       | —            |
| `record_payment_preference`      | EXECUTE | EXECUTE       | —            |
| `confirm_order_payment`          | —       | —             | EXECUTE      |
| `record_webhook_event`           | —       | —             | EXECUTE      |
| `mark_webhook_event`             | —       | —             | EXECUTE      |

`record_payment_preference` is `anon`/`authenticated`-callable because
its authorization is the same as RFC-006's `create_order_with_hold`/
`get_checkout_order`: possession of the raw checkout token (re-verified
inside the function itself, never trusted from the caller). It writes
only `orders.provider_preference_id`/`provider_checkout_url`, nothing
financial. `confirm_order_payment` — the actual payment-truth boundary —
is `service_role`-only, exactly mirroring RFC-006's
`expire_pending_orders()` precedent: a caller who merely knows an order
id can never invoke it, full stop; only trusted server-side code that
has already independently verified a payment with Mercado Pago's own API
holds the credential that can call it.

## Service-role decision

Webhook processing needs to call `confirm_order_payment` (and the two
webhook-bookkeeping functions), all three restricted to `service_role`.
`src/lib/supabase/service-role.ts` creates a narrow Supabase client using
`SUPABASE_SERVICE_ROLE_KEY`, imported **only** by
`src/features/payments/webhook.ts` — never by any client component,
never by any other route. This is a deliberate, narrow, explicitly-scoped
exception to the codebase's otherwise strict "anon client + SECURITY
DEFINER only" convention, justified specifically because
`confirm_order_payment`'s own privilege grant already restricts it to
`service_role` — the Supabase client's role and the function's grant are
the same boundary, not a workaround for RLS. `record_payment_preference`
deliberately does **not** need this (it runs through the ordinary
`anon` client, exactly like RFC-006's functions), keeping the
service-role client's blast radius as small as possible.

## Database changes

New migration: **`supabase/migrations/20260925000000_rfc_007_mercado_pago.sql`**
(forward-only — RFC-002 through RFC-006's migration files are
byte-for-byte untouched).

- `orders.provider_preference_id text`, `orders.provider_checkout_url
text`, both nullable; `unique (provider_preference_id)`.
- `get_checkout_order(uuid, text)` redefined via `drop function` +
  `create function` (not `create or replace` — the return column list
  changed, which Postgres disallows via replace) to additionally return
  `organization_id`, `provider_preference_id`, `provider_checkout_url`.
  Same authorization semantics, same grants, re-applied explicitly.
- `record_payment_preference(p_order_id uuid, p_checkout_token_hash
text, p_provider payment_provider, p_provider_preference_id text,
p_provider_checkout_url text) returns table(order_id,
provider_preference_id, provider_checkout_url)` — `SECURITY DEFINER`,
  `search_path = public, pg_temp`, granted to `anon, authenticated`.
- `confirm_order_payment(p_order_id uuid, p_provider payment_provider,
p_provider_payment_id text, p_status payment_status,
p_paid_amount_minor bigint, p_currency char(3), p_payment_method text,
p_provider_payload jsonb, p_approved_at timestamptz,
p_webhook_event_id uuid) returns table(outcome, order_id,
order_status, payment_id)` — `SECURITY DEFINER`,
  `search_path = public, pg_temp`, granted to `service_role` only.
- `record_webhook_event(p_provider payment_provider, p_provider_event_id
text, p_event_type text, p_payload jsonb) returns table
(webhook_event_id, already_existed, status)` — `SECURITY DEFINER`,
  granted to `service_role` only.
- `mark_webhook_event(p_webhook_event_id uuid, p_status webhook_status,
p_error_message text) returns void` — `language sql`, `SECURITY
DEFINER`, granted to `service_role` only.
- No new indexes were needed beyond the new unique constraint (which
  Postgres backs with its own index automatically); no existing index,
  constraint, or policy was dropped or altered.

## API routes

- `POST /api/payments/mercado-pago/preference` — body `{orderId,
checkoutToken}`, returns `{checkoutUrl}`. Thin handler
  (`src/app/api/payments/mercado-pago/preference/route.ts`) delegating
  to `src/features/payments/api.ts`.
- `POST /api/webhooks/mercado-pago` — reads the **raw** request body
  (`request.text()`, required for signature verification — a
  re-serialized/parsed body would not byte-match what Mercado Pago
  signed), forwards headers/query params + raw body to
  `src/features/payments/webhook.ts#processMercadoPagoWebhook`, returns
  whatever HTTP status that function decides (200/401/400/502 — see
  "Webhook HTTP behavior" below).
- `GET /api/orders/[orderId]/payment-status` — requires `?token=` (the
  RFC-006 checkout token; an order id alone is never sufficient),
  returns `{orderId, status}` where `status` is one of
  `PENDING_PAYMENT | PAID | PAYMENT_FAILED | EXPIRED` — no payment
  provider identifiers, no internal record, no amount.

## Webhook HTTP behavior

- **401**: invalid/missing/malformed signature. No database write at
  all.
- **200**: every case where Mercado Pago retrying would not help —
  already processed (`ALREADY_PROCESSED`), an unsupported/ignored event
  type, or a permanent domain mismatch (amount/currency/state/order-not-
  found) that has been durably recorded (`payments` + `audit_logs` +
  `webhook_events` marked `FAILED` with a safe diagnostic message) for
  human review. Returning non-2xx here would just make Mercado Pago
  retry something that can never succeed differently.
- **502**: Mercado Pago's own `GET /v1/payments/:id` call failed
  (network/provider outage) — genuinely transient, so a non-2xx is
  returned on purpose to trigger Mercado Pago's documented retry
  schedule.
- **400**: a `payment`-typed notification with no `data.id` at all
  (malformed, cannot even attempt a lookup).
- **500**: an unexpected failure recording the webhook receipt itself
  (should not happen in normal operation; distinct from every
  domain-level case above, all of which return 200).

## UI

- `src/features/payments/components/payment-button.tsx` (client
  component) — "Continuar al pago," posts to the preference endpoint,
  navigates the browser to the returned `checkoutUrl` on success.
  Rendered inside `src/features/checkout/components/checkout-summary.tsx`
  only while the order is `PENDING_PAYMENT`.
- `src/app/payment/result/page.tsx` (server component) — the single
  shared Mercado Pago return route for `back_urls.success/pending/failure`
  alike (RFC-007 section 17: return routes are presentation-only, so
  behavior can never depend on which back_url Mercado Pago actually used).
  Deliberately **never reads** the query parameters Mercado Pago appends
  (`payment_id`, `status`, `collection_status`, `merchant_order_id`, ...)
  — only Lucky Ticket's own `orderId`/`token` params, round-tripped
  through `back_urls`, are used, and only to call `getPaymentStatus` for
  the server-rendered initial state.
- `src/features/payments/components/payment-status-view.tsx` (client
  component) — polls `GET /api/orders/[orderId]/payment-status` every 2
  seconds, up to 30 attempts (1 minute), stops at any terminal status
  (`PAID`/`PAYMENT_FAILED`/`EXPIRED`) or once the attempt cap is hit.
  Renders exactly the four required states in Spanish: "Estamos
  verificando tu pago..." (`PENDING_PAYMENT`), "¡Pago confirmado!"
  (`PAID`), "No pudimos confirmar el pago" (`PAYMENT_FAILED`), "La
  reserva venció" (`EXPIRED`). No internal provider error text is ever
  exposed.

## Checkout token preservation across the redirect

The RFC-006 checkout token travels in Lucky Ticket's own
`back_urls`/`notification_url` query string
(`/payment/result?orderId=..&token=..`) so the result page can keep
using the same token-authorized read boundary (`getPaymentStatus`,
built on `get_checkout_order`) after the buyer returns from Mercado
Pago. **Security implication, stated explicitly**: this means the raw
checkout token is sent to, and retained by, Mercado Pago as part of the
preference's `back_urls` — a third party now holds a value that
authorizes read access to this one order's status. This was a conscious
tradeoff for RFC-007's scope rather than building a separate,
minted-fresh payment-return token: the checkout token is already
short-lived (tied to the order's hold window, extended only as far as
the buyer needs to complete payment), authorizes **read-only** access to
non-sensitive order status (never PII, never payment credentials, never
a write path), and Mercado Pago is already a trusted party in this flow
by construction (it is the payment processor). This is documented here
as a known, accepted scope decision, not silently glossed over — a
future RFC could replace it with a dedicated, single-use "payment
return" token minted at preference-creation time if a stricter posture
is ever required.

## Redirect security

`back_urls`/`notification_url` are built **exclusively** from
`NEXT_PUBLIC_APP_URL` (a trusted, server-configured environment
variable), never from any request header (`Host`, `Origin`,
`X-Forwarded-Host`) and never from any browser-supplied query parameter
or body field. There is no code path where a value the browser controls
can influence which URL Mercado Pago redirects the buyer to, or which
URL Mercado Pago sends webhook notifications to — eliminating open
redirect as a concern by construction rather than by validation.

## Server-only provider code

`src/lib/mercado-pago/client.ts`, `src/lib/supabase/service-role.ts`,
and `src/features/payments/{api,webhook}.ts` all begin with `import
"server-only"`. `src/lib/mercado-pago/signature.ts` also carries the
guard even though its functions take `secret` as a plain parameter
(no env access of its own) — belt-and-suspenders, since it is part of
the credential-handling call chain and the guard costs nothing.
`src/services/payment-gateway/mercado-pago-payment-gateway.ts` is
likewise server-only by construction (it only ever receives an
already-configured gateway instance created inside server code).

## Files created / modified

**Created:** `supabase/migrations/20260925000000_rfc_007_mercado_pago.sql`;
`supabase/tests/database/rfc_007_payments.test.sql`;
`scripts/rfc-007-concurrency-test.sh`;
`scripts/test-mercado-pago-signature.mjs`;
`src/lib/mercado-pago/{client,signature,mapper}.ts`;
`src/lib/supabase/service-role.ts`;
`src/services/payment-gateway/{payment-gateway,mercado-pago-payment-gateway}.ts`;
`src/features/payments/{errors,schemas,types,queries,api,webhook}.ts`;
`src/features/payments/components/{payment-button,payment-status-view}.tsx`;
`src/app/api/payments/mercado-pago/preference/route.ts`;
`src/app/api/webhooks/mercado-pago/route.ts`;
`src/app/api/orders/[orderId]/payment-status/route.ts`;
`src/app/payment/result/page.tsx`;
`docs/rfcs/RFC-007-mercado-pago-payments.md` (this document).

**Modified:** `src/lib/env/server.ts` (added `getPaymentServerEnv`,
existing `getServerEnv`/`isServerEnvConfigured` untouched);
`.env.example` (added the four RFC-007 variables with inline
documentation); `src/types/database.ts` (regenerated by hand for the
schema/function changes above — see "Validation results" for why this
was hand-edited rather than `supabase gen types`-generated);
`src/features/checkout/components/checkout-summary.tsx` (renders
`PaymentButton` while `PENDING_PAYMENT`); `src/app/checkout/[orderId]/page.tsx`
(threads the checkout token through to `CheckoutSummary`); `package.json`
/ `package-lock.json` (added the `mercadopago` dependency).

## Testing

`supabase/tests/database/rfc_007_payments.test.sql` — 74 pgTAP
assertions:

- **Function privileges** (01-14): EXECUTE grants for
  `record_payment_preference`/`confirm_order_payment`/
  `record_webhook_event`/`mark_webhook_event`/`get_checkout_order`
  across `anon`/`authenticated`/`service_role`/PUBLIC, verified via
  direct `pg_proc`/`aclexplode` catalog lookups (not
  `function_privs_are`'s schema+argtypes form, to avoid any risk of
  mis-spelling a catalog type name like `char(3)`'s internal `bpchar`).
- **RLS still enabled** (15-17): `payments`/`webhook_events`/`orders`.
- **Direct table-access denial** (18-22): `anon` cannot `SELECT`/`INSERT`
  `payments`/`webhook_events`; an `authenticated` caller with no
  resolvable `auth.uid()` fares the same.
- **Confirmation RPC unreachable by anon/authenticated** (23-24):
  `confirm_order_payment` throws `permission denied for function` for
  both roles, even an organization's own `OWNER`.
- **`record_payment_preference`** (25-28): happy path, persistence
  visible on `orders`, wrong-token rejection, expired-order rejection.
- **Happy path** (29-36): `PAID` transition, `paid_at` stamped, exactly
  one `payments` row, correct persisted amount, duplicate-webhook
  idempotency (same outcome, same `payment_id`, still exactly one row).
- **Concurrent-duplicate DB backstop** (37): a raw duplicate `INSERT`
  into `payments` for an already-used `(provider, provider_payment_id)`
  raises `unique_violation` — the constraint `confirm_order_payment`'s
  exception handler depends on genuinely exists.
- **Already-PAID collision** (38-39): a second, different approved
  payment for an already-PAID order is recorded, never re-transitions,
  audit-logged.
- **External-reference / order-not-found** (40-41): a nonexistent order
  id raises a stable domain error, no payment row created.
- **Currency mismatch** (42-43), **amount mismatch** (44-46, including a
  successful retry with a new `provider_payment_id`).
- **Rejected-attempt-is-retryable** (47-50): a `REJECTED` attempt leaves
  the order `PENDING_PAYMENT` with its hold still active; a subsequent
  approved attempt succeeds.
- **Inventory no-double-counting** (51-55): a 2-unit ticket type, two
  pending holds consuming both, confirming one to `PAID`, availability
  asserted still exactly `0` afterward (not `-1`, not `1`).
- **Payment-vs-expiration race** (56-62): late-but-genuine payment
  honored when capacity remains (`PAID_LATE_RECOVERY`); late payment
  rejected once capacity was legitimately reclaimed by another order
  (`REJECTED_INVENTORY_UNAVAILABLE`), order still reported `EXPIRED` via
  `get_checkout_order`'s virtual derivation, payment still recorded,
  audit-logged.
- **`record_webhook_event`/`mark_webhook_event` idempotency** (63-69):
  first delivery vs. redelivery, same row returned, status transitions,
  DB-level unique-constraint backstop.
- **Browser-cannot-mark-PAID** (70-72): a raw `UPDATE orders SET status
= 'PAID'` by `anon` and by an owning organization's `authenticated`
  `OWNER` leaves the order unchanged (no client-facing UPDATE policy
  exists); `get_checkout_order` is confirmed to be an ordinary read-only
  function (`prokind = 'f'`), never a side-effecting one.
- **Cross-org isolation** (73-74): Org A's OWNER can see Org A's
  payment; Org B's OWNER cannot.

`scripts/rfc-007-concurrency-test.sh` — two real, concurrent `psql`
connections both calling `confirm_order_payment` with the **same**
`provider_payment_id` for the same order at the same instant (mirrors
`scripts/rfc-006-concurrency-test.sh`'s precedent, since pgTAP's single
transaction/connection cannot exercise two backends truly racing the
same row lock). Asserts: exactly one call produces `PAID`/
`PAID_LATE_RECOVERY`, the other resolves to `ALREADY_PROCESSED` pointing
at the same `payment_id`, exactly one `payments` row exists afterward,
and the order ends up `PAID` exactly once. **Documented, not executed**
in this environment — see "Validation results."

`scripts/test-mercado-pago-signature.mjs` — 21 deterministic, dependency-
free assertions against the **real** `src/lib/mercado-pago/signature.ts`
source (not a hand-duplicated copy — the script strips only the
`import "server-only"` line from the actual file at test-run time and
dynamically imports the result, so a bug in the real implementation
cannot hide behind a stale copy). Covers `parseSignatureHeader` (valid,
missing, empty, malformed, missing-`ts`, missing-`v1`), `buildManifest`
(all-fields-present, lowercasing, omission of missing `dataId`/`requestId`
segments), and `verifyWebhookSignature` end-to-end (valid; wrong secret;
missing header; malformed header; tampered `v1`; replayed against a
different `data.id`; replayed with a different `x-request-id`; non-hex
`v1`; wrong-length `v1`). **Executed** in this environment — see
"Validation results" for the actual run output.

No Vitest/Jest test framework exists in this project (`package.json` has
no test runner at all); introducing one solely to cover this one pure-
function module was judged disproportionate infrastructure for RFC-007's
scope ("avoid overengineering") and is left as a documented
recommendation rather than done here — see "Known limitations."

## Validation results

Run from the Mac (`~/Desktop/lucky-ticket`), in order:

- `npx supabase status` — **fails**: `failed to inspect container
health: docker: command not found (podman also not found)`. No
  Docker/Podman is installed in this environment (same limitation
  RFC-006 already documented; re-confirmed here, not silently skipped).
- `npx supabase db reset`, `npx supabase test db`, `npx supabase gen
types typescript --local` — **not runnable** for the same reason (no
  local Postgres container available). `src/types/database.ts` was
  therefore hand-edited to match the migration's schema/function changes
  exactly (new `orders` columns, `get_checkout_order`'s new return
  columns, and the four new RPC entries with their exact argument/return
  shapes) rather than tool-generated — an accepted limitation, not a
  substitute claimed to be equivalent.
- `npm run typecheck` (`tsc --noEmit`) — **passes**, zero errors.
- `npm run lint` (`eslint .`) — **passes**, zero errors/warnings.
- `npm run format:check` (`prettier --check .`) — **passes** on every
  file this RFC touched (one pre-existing, unrelated warning on
  `supabase/.temp/linked-project.json`, a Supabase-CLI-generated,
  untracked temp file this RFC never wrote to or read from — left
  alone).
- `npm run build` (`next build`) — **passes**: compiles successfully,
  all three new routes (`/api/payments/mercado-pago/preference`,
  `/api/webhooks/mercado-pago`, `/api/orders/[orderId]/payment-status`)
  and `/payment/result` appear correctly in the route manifest as
  dynamic (`ƒ`) routes.
- `node scripts/test-mercado-pago-signature.mjs` — **passes**, 21/21
  assertions, against the real `signature.ts` implementation.

The pgTAP suite and the two-connection concurrency script could not be
executed against a real Postgres in this environment (no Docker/Podman
in the cloud sandbox — `ghcr.io` image pulls are blocked there — and no
Docker/Podman/Postgres binary at all on the Mac's bridged Cowork VM).
Both were written and manually re-derived line-by-line against the
migration's exact function signatures/return shapes/error codes during
this session, but their **pass/fail status against a live database is
unverified** — this is stated plainly rather than glossed over, exactly
as RFC-006's own report had to state for its own pgTAP suite.

## Mercado Pago sandbox QA

**Not executed** in this environment: no Mercado Pago sandbox/test
credentials were available, and there is no way to complete a real
Checkout Pro payment (even a sandbox one) without a working browser
session against Mercado Pago's actual hosted checkout page, which this
session has no access to. This is stated explicitly rather than implied
or omitted — RFC-007's instruction to distinguish "actually executed"
from "documented but not executed" is taken literally here: **nothing**
in this section was executed.

**Documented for a future manual QA pass**, per current official
guidance: create a Mercado Pago Developers account, create a test
application, generate `TEST-` prefixed sandbox credentials (the SDK/
gateway already branches on `MERCADO_PAGO_ACCESS_TOKEN.startsWith("TEST-")`
to select `sandbox_init_point` over `init_point`), create test buyer
accounts in the Mercado Pago Developers panel (a separate test user from
the seller's own test account, since Mercado Pago does not allow a
single test account to pay itself), and use Mercado Pago's published
test card numbers (which vary by country and are looked up at QA time
from the current Developers panel, not hard-coded here, since they
change without notice). The scenarios worth running once sandbox access
exists: a full approved-payment round trip; a card configured to
simulate `rejected`; abandoning checkout mid-flow (`pending`/`failure`
back_url); and the two explicitly-required security probes below.

## Local webhook testing

Mercado Pago cannot call `localhost` — its servers need a publicly
reachable HTTPS URL for `notification_url`. No tunnel (ngrok, Cloudflare
Tunnel, etc.) was introduced automatically in this session, and nothing
was deployed, per RFC-007's explicit instructions not to introduce a
tunneling dependency automatically or deploy without approval. **For a
future manual QA pass**, either of two standard approaches would work:
(1) an HTTPS tunnel (e.g. `ngrok http 3000`) pointed at a local `next
dev` server, with `NEXT_PUBLIC_APP_URL` temporarily set to the tunnel's
HTTPS URL so `notification_url` resolves publicly; or (2) a deployed
staging environment with its own Mercado Pago sandbox credentials.
Either requires the person doing that QA to explicitly choose and set up
the option — not something this RFC does on its own.

## Manual E2E

Not executed, for the same reason as "Mercado Pago sandbox QA" above (no
sandbox credentials, no way to complete a real hosted checkout in this
session). Explicitly **not claimed** as done. The two mandatory security
probes RFC-007 calls out — visiting a fabricated
`/payment/result?orderId=...&token=...` success URL for an order that
was never actually paid, and appending fake Mercado Pago-style query
parameters (`?status=approved&payment_id=999`) to that same URL — are
both structurally guaranteed to be safe by the result page's own design
(it never reads those query parameters at all, and always re-derives
status from `getPaymentStatus`/`get_checkout_order`, which reads the
real `orders.status` column), and this is exercised at the database
level by pgTAP tests 70-72 (a raw UPDATE cannot flip the order to PAID,
and `get_checkout_order` is confirmed read-only) rather than by an
actual browser visit to a running server, since no running server/local
Supabase stack existed to visit in this session.

## Assumptions

- Node 22 / Next.js 16 are already the project's runtime (confirmed via
  `package.json`/`node --version` on the Mac) — the `mercadopago` SDK's
  stated Node >= 18 requirement is satisfied without any additional
  configuration.
- A single platform-wide Mercado Pago account is an acceptable MVP for
  this RFC's scope, per the RFC's own explicit permission to do so
  ("if using a single server-side account for dev/sandbox, clearly
  document this as an MVP/development limitation").
- `NEXT_PUBLIC_SUPABASE_URL` pointing at `http://127.0.0.1:54321` in
  `.env.local` was treated as confirmation that local Supabase (not
  Cloud) is the intended environment for any destructive testing — no
  destructive operation was attempted against a Cloud-looking URL, and
  none was attempted at all given the Docker/Podman limitation.
- The ticket type id (`order_items.ticket_type_id`, already returned by
  `get_checkout_order`'s `items` jsonb as `ticketTypeId`) is an
  acceptable, safe, non-secret value to use for Mercado Pago's required
  `Items.id` field — it identifies which product was sold, carries no
  buyer information, and was already being returned to the (token-
  authorized) buyer's own browser anyway.

## Known limitations

- **Single-platform-account settlement** (see "Multi-tenant payment
  architecture"): every organizer's sales currently settle into one
  Mercado Pago account, not each organizer's own. Explicitly not solved
  here.
- **No automated reconciliation for `REJECTED_INVENTORY_UNAVAILABLE`**:
  a genuinely-paid, capacity-lost order is recorded for manual human
  reconciliation, not automatically refunded or re-ticketed.
- **No refunds/chargebacks handling** at all (explicit non-goal) — a
  `charged_back`/`refunded` provider status maps into Lucky Ticket's
  internal `REFUNDED` payment status via `mapper.ts`, but nothing acts
  on it; this RFC only ever writes a `payments` row reflecting it, it
  never reverses an order's `PAID` state.
- **The pgTAP suite and the two-connection concurrency script are
  unverified against a live database** in this environment (no local
  Supabase/Docker available anywhere this session could reach) — see
  "Validation results."
- **No Mercado Pago sandbox QA or manual E2E was actually performed** —
  see those sections above; both are documented for a future pass, not
  claimed as done.
- **No unit-test framework exists in this project** — the webhook
  signature tests run as a standalone Node script rather than
  Vitest/Jest tests; introducing a framework is a reasonable follow-up
  but was judged out of RFC-007's scope to add unprompted.
- **Checkout token travels to Mercado Pago via `back_urls`** — an
  accepted tradeoff, explicitly documented under "Checkout token
  preservation," not a silent gap.
- **`src/types/database.ts` was hand-edited**, not `supabase gen
types`-generated, because no local Postgres was reachable — a careful
  manual match to the migration's actual return shapes, but not
  tool-verified.

## RFC-008 handoff

RFC-007 finishes with: `orders.status = 'PAID'` and `orders.paid_at` set,
via a single atomic, idempotent, provider-verified transition; a
`payments` row persisted and reconciled against the order's authoritative
amount/currency/identity; inventory correctly and permanently committed
with no double-counting window, ever; and webhook processing that is
safe to receive any number of times. RFC-008 picks up from exactly that
point to issue tickets, generate secure per-ticket tokens, store SHA-256
QR hashes, and handle delivery (email via Resend, per the project's
existing plan) — none of which RFC-007 touches. RFC-008 should be able
to trigger entirely off `orders.status = 'PAID'` becoming true (e.g. via
a query for `PAID` orders with no yet-issued tickets), without needing
to know anything about Mercado Pago, webhooks, or payment verification
at all — that boundary is exactly where this RFC stops.

## Security checklist

- [x] No Mercado Pago credential (`MERCADO_PAGO_ACCESS_TOKEN`,
      `MERCADO_PAGO_WEBHOOK_SECRET`) is ever sent to the browser.
- [x] No `NEXT_PUBLIC_*` environment variable holds a secret.
- [x] `SUPABASE_SERVICE_ROLE_KEY` is read only inside
      `src/lib/supabase/service-role.ts`, imported only by webhook
      processing code.
- [x] Every payment-credential-touching module is `server-only`
      (`client.ts`, `service-role.ts`, `signature.ts`, `api.ts`,
      `webhook.ts`).
- [x] The browser never sends price/total/currency/status to the
      preference-creation endpoint — only `{orderId, checkoutToken}`.
- [x] Preference items are built exclusively from
      `order_items`/`ticket_types` via `get_checkout_order`, never from
      request body fields.
- [x] `external_reference` is the order's own id, set server-side, never
      browser-influenced.
- [x] `back_urls`/`notification_url` are built exclusively from
      `NEXT_PUBLIC_APP_URL`, never from a request header or browser
      input — no open redirect is possible.
- [x] The result page never reads Mercado Pago's redirect query
      parameters (`payment_id`, `status`, `collection_status`, ...) as
      truth.
- [x] The result page never declares success without querying
      authoritative state (`getPaymentStatus`).
- [x] `orders` has no client-facing UPDATE policy — verified by pgTAP
      (tests 70-71), not merely asserted.
- [x] `confirm_order_payment` is granted to `service_role` only —
      verified by pgTAP (tests 04-06), not merely asserted.
- [x] `record_webhook_event`/`mark_webhook_event` are granted to
      `service_role` only — verified (tests 07-12).
- [x] Every SECURITY DEFINER function sets an explicit, locked
      `search_path = public, pg_temp`.
- [x] Every SECURITY DEFINER function re-verifies its own
      authorization/state (checkout token, payability, order state) —
      never trusts that its caller already checked.
- [x] Webhook signature verification happens **before** any database
      write — an unauthenticated request can create zero rows, not even
      a `webhook_events` one keyed by an attacker-controlled id.
- [x] Signature comparison uses `timingSafeEqual`, with an explicit
      length-mismatch guard so a malformed value can't throw.
- [x] The webhook body's amount/currency/status/order-identity fields
      are never treated as authoritative — only the independently-fetched
      `GET /v1/payments/:id` response is.
- [x] Amount/currency comparison is integer (`bigint`) equality in
      Postgres, never floating point, anywhere in the authoritative
      path.
- [x] `payments(provider, provider_payment_id)` and
      `webhook_events(provider, provider_event_id)` are enforced as
      database-level `UNIQUE` constraints (RFC-002, reused), not
      application-only checks — verified by pgTAP (tests 37, 69) with a
      raw duplicate-insert probe.
- [x] `confirm_order_payment` catches `unique_violation` explicitly
      rather than assuming its own prior `SELECT` check is race-free.
- [x] No raw provider payload is dumped into an arbitrary public JSON
      column without justification — `payments.provider_payload` and the
      webhook's `safePayloadSubset` both carry a narrow, deliberately
      chosen field set.
- [x] Logging includes order id, provider payment id, preference id,
      webhook event id, and a processing outcome, but never a credential,
      token, or full raw provider payload.
- [x] No `git commit` was made, no `supabase db push` was run, no
      production Mercado Pago credentials were configured, no production
      webhook configuration was touched.
- [x] Ticket issuance, QR generation, and email sending are not
      implemented anywhere in this RFC's code.
- [x] Refunds/chargebacks are not implemented — a `REFUNDED` mapped
      status is recorded, never acted upon.
- [x] `payment_accounts` (RFC-002) is untouched — no row written, no
      code path reads it, preserving the future organizer-account
      extension point without pretending to have built it.
- [x] The checkout token's presence in `back_urls` is a documented,
      conscious tradeoff, not a silent gap (see "Checkout token
      preservation").
- [x] `.env.local` was not modified with real credentials; no secret
      value appears anywhere in this document or in terminal output
      reviewed for this report.
- [x] Cross-organization isolation on `payments` was verified by pgTAP
      (tests 73-74), not merely assumed to be inherited from RFC-002.
