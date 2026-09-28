# RFC-006 — Orders & Inventory

## Status

Implemented and locally verified (see "Testing strategy" and "Known
limitations" for exactly what "verified" means in this environment). **Not
committed, not pushed to Supabase Cloud** — this document describes the
local implementation pending review, per the RFC's own final instruction.

## Problem

RFC-005 gave Lucky Ticket a read-only public event page: an anonymous
visitor can see a published event and its public ticket types, but the
`[ Select ]` button is a disabled placeholder. There is no way for anyone
to actually buy a ticket. RFC-006 turns that placeholder into the
beginning of a real purchase flow — select tickets, enter buyer
information, create an order, reserve inventory — without yet touching
payment.

## Goals

- An anonymous buyer can select ticket quantities, enter their name and
  email, and create an order.
- The order is created directly as `PENDING_PAYMENT` with a real,
  concurrency-safe inventory reservation (a `ticket_holds` row per line).
- Lucky Ticket **never** sells or reserves more tickets than a ticket
  type's configured capacity, even under concurrent checkout requests —
  proven, not just implemented (see "Concurrency strategy").
- The buyer can return to a checkout confirmation page
  (`/checkout/[orderId]?token=...`) using a secure, single-use access
  token — never their order's UUID alone.
- Every price, subtotal, total, availability check, and tenant
  relationship is computed and re-verified by PostgreSQL, never trusted
  from the browser.

## Scope

Anonymous checkout, atomic order + inventory-hold creation, a secure
checkout access token, the public checkout API (`POST /api/checkout`), the
checkout confirmation page, and an idempotent `expire_pending_orders()`
lifecycle function.

## Non-goals

This RFC explicitly does **not** implement: Mercado Pago, Checkout Pro,
Mercado Pago OAuth, payment creation, payment preference creation, payment
webhooks, payment reconciliation, the `PENDING_PAYMENT` → `PAID`
transition, ticket issuance, QR generation, QR scanning, ticket emails,
Resend, check-in, refunds, chargebacks, billing settlements, platform fee
collection, promo codes, discount campaigns, promoters, resale, ticket
transfer, seat maps, merchandising, scheduled external cron infrastructure,
service-role checkout, or native apps. All of these arrive in RFC-007 or
later.

## Inspecting existing architecture first

Before writing any code, the following were read in full: RFC-002's
schema and RLS (`orders`, `order_items`, `ticket_holds`, `customers`,
`ticket_types`), the generated `Database` types, RFC-003's `SECURITY
DEFINER`/privilege-grant precedent (`create_organization`), RFC-004's
`ticket_types` columns and triggers, and RFC-005's entire public read path
(`src/lib/supabase/public.ts`, `src/features/events/public/*`). Every
table this RFC needs already existed with the right columns — `orders`
already had `status`/`expires_at`/`subtotal_amount`/`total_amount`/
`buyer_name`/`buyer_email`, `order_items` already had a price-snapshot
shape, `ticket_holds` already had `quantity`/`expires_at`/`order_id`,
`customers` already had an organization-scoped unique constraint on
`normalized_email`. **Exactly one column was added**:
`orders.checkout_token_hash` — RFC-002 never anticipated an anonymous
buyer needing to prove ownership of an order without an account. No table
was redesigned "because a cleaner schema might exist" — RFC-002's schema
was reused as-is.

## Buyer flow

```text
Public Event page (RFC-005)
  → buyer selects ticket quantities (client-only React state — NO
    database write yet)
  → buyer enters name + email
  → "Continue to checkout" → POST /api/checkout
      → create_order_with_hold(...) in Postgres:
          resolve org/event → validate → lock ticket types
          (ascending id order) → recompute availability → validate
          every line → resolve/create customer → create order
          (PENDING_PAYMENT) → create order_items → create
          ticket_holds → COMMIT
      → raw checkout token generated + hashed in Node, hash stored,
        raw token returned to the buyer exactly once
  → redirect to /checkout/[orderId]?token=<rawToken>
      → get_checkout_order(orderId, hash(token)) → narrow DTO
      → checkout confirmation page: totals, items, countdown,
        disabled "Continuar al pago" CTA (RFC-007's job)
```

## Order lifecycle

RFC-006 creates orders **directly** as `PENDING_PAYMENT` (never `DRAFT` —
there is no multi-step in-database cart). The only lifecycle transition
this RFC implements is `PENDING_PAYMENT` → `EXPIRED`, via
`expire_pending_orders()`. `PENDING_PAYMENT` → `PAID` is explicitly **not**
implemented — that is RFC-007's Mercado Pago webhook. `PAYMENT_FAILED`,
`CANCELLED`, `REFUNDED`, `PARTIALLY_REFUNDED` are pre-existing enum values
this RFC never produces or consumes.

## Inventory model

Available inventory for a ticket type is **never a stored counter**. It is
derived, at the moment it's needed, as:

```text
available = ticket_types.quantity
  - SUM(order_items.quantity)  for PAID orders on this ticket type
  - SUM(ticket_holds.quantity) for PENDING_PAYMENT orders on this ticket
                                type, WHERE ticket_holds.expires_at > now()
```

The `PAID` term does nothing today (RFC-006 never creates a `PAID` order)
but is included now so RFC-007 can introduce `PAID` orders without
changing this formula at all — see "RFC-007 handoff". The
`PENDING_PAYMENT` term automatically excludes an expired hold
(`expires_at > now()`) with **zero dependency** on `expire_pending_orders()`
ever having run (see "Expiration semantics"). It also automatically stops
counting a hold the moment its order leaves `PENDING_PAYMENT` — e.g. a
future `PAID` transition — because the join filters on
`o.status = 'PENDING_PAYMENT'`, so RFC-007 will not need to touch or delete
a paid order's hold row for this formula to remain correct.

This exact expression is duplicated deliberately in three places: the
per-line lock/validate loop inside `create_order_with_hold`, and
`get_public_ticket_availability` (RFC-005's public `SOLD_OUT` signal). It
is not factored into a shared helper — see the "Public API boundary"
section for why. All three must be kept in sync if this formula ever
changes; the migration's header comment says so explicitly.

`ticket_types.quantity` (RFC-004's existing capacity column) is reused
as-is. No mutable `available_quantity` counter was introduced — RFC-006
explicitly discourages one "unless there is an extremely strong
architectural reason," and deriving from `order_items`/`ticket_holds`
under a row lock is both simpler and impossible to let drift out of sync
with the rows it's summarizing.

## Active hold definition

A `ticket_holds` row consumes inventory **only** while `expires_at > now()`
— evaluated fresh, every time availability is computed, never cached.
Expired hold rows are never deleted; they remain for auditing, but stop
counting the instant their timestamp passes, with or without any cleanup
job having run.

## Hold duration

Centralized as a constant in two places — one per layer, since there is no
shared build artifact between SQL and TypeScript:

- `src/lib/checkout/constants.ts`: `CHECKOUT_HOLD_MINUTES = 10`
- The migration's `v_hold_minutes constant int := 10` inside
  `create_order_with_hold`

`expires_at` is computed **inside the database**
(`now() + make_interval(mins => v_hold_minutes)`) at order-creation time —
the browser never supplies, sees before creation, or influences this
value.

## Expiration semantics

Two independent things, on purpose:

1. **Inventory correctness** — never depends on any scheduled job. The
   inventory formula above is timestamp-aware by construction
   (`expires_at > now()`), so an expired hold stops consuming inventory
   the instant its clock passes, even if the order's `status` column still
   says `PENDING_PAYMENT`.
2. **Lifecycle bookkeeping** — `expire_pending_orders()` transitions
   `PENDING_PAYMENT` → `EXPIRED` for orders whose `expires_at` has passed.
   Idempotent by construction: its own `UPDATE ... WHERE status =
'PENDING_PAYMENT' AND expires_at <= now()` simply matches zero rows on
   a second run — already-expired, paid, or cancelled orders are
   untouched no matter how many times this runs.

No cron infrastructure is wired up (RFC-006 explicitly says not to add
one yet). `expire_pending_orders()` is `SECURITY DEFINER`, granted to
`service_role` only, and is meant to be invoked later by Supabase's
`pg_cron` or a scheduled Edge Function. Until then it can be run manually
by an operator holding the service-role key.

`get_checkout_order` independently derives an `EXPIRED` status for display
the instant `expires_at` has passed, regardless of whether
`expire_pending_orders()` has run — "cleanup is not inventory correctness"
applies equally to what the buyer is _told_, not just to what inventory
_counts_.

## Concurrency strategy

**This is the most important technical decision in RFC-006.**

`create_order_with_hold` takes `SELECT ... FOR UPDATE` row locks on the
specific `ticket_types` rows a checkout touches — a plain Postgres row
lock, no advisory lock, no extra mechanism. It:

1. Iterates the buyer's cart in **deterministic ascending `ticket_type.id`
   order** (`order by (value->>'ticketTypeId')::uuid`), regardless of the
   order the JSON cart array lists them in.
2. Locks each ticket type row (`for update`).
3. **Only after acquiring the lock**, recomputes availability from a fresh
   `SELECT` against `order_items`/`ticket_holds` — never a value read
   before the lock, never a value trusted from an earlier step.
4. Validates the requested quantity against that freshly-locked
   availability.
5. Accumulates the line into an in-memory list; **no row is written yet.**
6. Only after every line in the cart passes validation does the function
   insert the `orders` row, then loop over the validated lines to insert
   `order_items` and `ticket_holds`.

Two concurrent calls touching the same ticket type: the second call's
`FOR UPDATE` blocks until the first call's transaction commits or rolls
back. Once unblocked, it recomputes availability from scratch — so it
always sees the first call's committed reservation, never a stale read. If
the first call already consumed the only remaining unit, the second call's
own check fails and the entire function raises an exception, which rolls
back everything — no partial order, no partial `order_items`, no partial
`ticket_holds`.

### Deterministic lock ordering (deadlock avoidance)

Locking every ticket type in the **same** order regardless of the buyer's
cart order is the classic lock-ordering deadlock-prevention rule. If Buyer
A's cart is `[General, VIP]` and Buyer B's cart is `[VIP, General]`, both
transactions still attempt to lock the lower-`id` ticket type first — so
one of them always wins that first lock before either tries for the
second. Neither can ever be stuck holding one lock while waiting on a lock
the other already holds and won't release.

```text
Without deterministic ordering (possible deadlock):
  Buyer A: lock(General) --wait--> lock(VIP)
  Buyer B: lock(VIP)     --wait--> lock(General)
  → each waits on a lock the other holds → deadlock

With deterministic ordering (ascending id, General.id < VIP.id here):
  Buyer A: lock(General) --wait--> lock(VIP)
  Buyer B: lock(General) --wait--> lock(VIP)     (same order!)
  → one of them acquires General first and proceeds; the other simply
    waits its turn on General - no cycle is possible
```

### Multi-ticket atomicity

Because the actual `INSERT`s only happen after **every** line has passed
validation (step 6 above), a cart where one line has plenty of inventory
and another line doesn't fails as a whole — the function raises before
inserting anything, so the transaction rolls back the entire attempt. A
buyer requesting 2 General (available) + 1 VIP (sold out) gets zero
General tickets reserved, not 2.

### Concurrency diagram

```text
 Request A (1 ticket)        ticket_types row         Request B (1 ticket)
       |                     capacity = 1                    |
       |--- BEGIN ---------------------------------------->  |
       |--- SELECT ... FOR UPDATE ---> [locked by A]          |
       |                                                      |--- BEGIN
       |                                                      |--- SELECT ... FOR UPDATE
       |                                                      |    [BLOCKS - A holds the lock]
       |--- recompute availability: 1 available --------------|
       |--- INSERT order/order_items/ticket_holds ------------|
       |--- COMMIT ------------------> [lock released] ------>|
       |                                                      |--- [unblocks, acquires lock]
       |                                                      |--- recompute availability: 0 available
       |                                                      |--- raise LT005 (INSUFFICIENT_INVENTORY)
       |                                                      |--- ROLLBACK (nothing written)

Result: exactly one order created. Never zero, never two.
```

### Proof, not just a lock

pgTAP runs everything in a single backend/single transaction, so it
**cannot** demonstrate two overlapping transactions racing on the same
lock. `scripts/rfc-006-concurrency-test.sh` opens two real, independent
`psql` connections and launches them concurrently with `&`/`wait` against
a running Postgres instance. See "Concurrency test" under "Testing
strategy" for the exact methodology and the actual results obtained this
session.

## Customer handling

Anonymous checkout still creates a `customers` row, reusing RFC-002's
existing `customers_org_normalized_email_key` unique constraint as the
conflict target for `INSERT ... ON CONFLICT ... DO UPDATE`. This means:

- The same email checking out twice **within the same organization**
  reuses the existing customer row (updates `last_seen_at`, backfills
  `name` if it was previously null).
- The same email checking out under a **different** organization always
  creates a distinct, separate `customers` row — the constraint and the
  `INSERT` are both scoped by `organization_id`, so cross-organization
  customer reuse is structurally impossible, not just discouraged.
- No customer table is ever exposed to `anon` directly — the only way a
  `customers` row is created or read is through this function.

## Checkout access token design

**The problem:** RFC-006 section 23 — an order's UUID alone must never be
sufficient to read it back. There is no `to anon` policy of the form
`orders.id = ...`, however narrow; anyone who saw or guessed an order id
would be able to read it.

**Generation.** `src/lib/checkout/token.ts`:

```text
rawToken  = crypto.randomBytes(32).toString("hex")   // 256 bits, Node, trusted server code
tokenHash = crypto.createHash("sha256").update(rawToken).digest("hex")
```

Never `Math.random()` — not cryptographically secure. Generated in
trusted Next.js server code (the Route Handler, via
`src/features/checkout/api.ts`), **not** inside Postgres — Postgres never
sees or computes the raw token, only ever receives the pre-computed hash
as a parameter.

**Storage.** `orders.checkout_token_hash` (new nullable, unique `text`
column) stores **only** the hash. The raw token is never persisted
anywhere, never logged, and is returned to the buyer exactly once — in
`POST /api/checkout`'s response body.

**Verification.** `get_checkout_order(p_order_id, p_checkout_token_hash)`
hashes nothing itself (the caller — `src/features/checkout/queries.ts` —
hashes the raw token from the URL's `?token=` param before calling it) and
requires an exact match on **both** `id` **and** `checkout_token_hash`. A
missing order id, a wrong order id, a missing token, and a wrong token all
raise the identical `LT008` / `INVALID_CHECKOUT_TOKEN` error — this
function never confirms an order id exists on its own. A valid token for
order A cannot be used to read order B: the hash comparison is an exact
column match, not a prefix or pattern.

**Why an order id alone is insufficient:** order ids are sequential-ish
UUIDs generated server-side and are visible in the URL
(`/checkout/[orderId]`) and could appear in logs, referrer headers, or be
guessed via enumeration if UUIDv4 collision resistance were ever
weakened. The token is the actual capability — knowing it is what proves
"I am the buyer who just created this order," not knowing its id.

## Public API boundary

Three new `SECURITY DEFINER` functions are the **entire** anonymous
write/read surface for commerce data — no new RLS policy was added for
`anon` on `orders`/`order_items`/`ticket_holds`/`customers`.

**Why not RLS policies instead?** RLS policies are evaluated per-row, not
per-transaction. They cannot express "lock this ticket_types row,
recompute availability under that lock, and only then allow the
order/order_items/ticket_holds inserts as one atomic unit." Two separate
PostgREST requests hitting separate INSERT policies could always race and
reintroduce the exact overselling bug this RFC exists to prevent.

**The three functions:**

- `create_order_with_hold(...)` — granted to `anon`, `authenticated`.
- `get_checkout_order(...)` — granted to `anon`, `authenticated`.
- `get_public_ticket_availability(p_event_id)` — granted to `anon`,
  `authenticated`. Returns **only** `{ticket_type_id, is_sold_out}` — never
  a raw count, hold record, order id, or customer field. RFC-005's public
  page is the caller.
- `expire_pending_orders()` — granted to `service_role` **only**.

Every `SECURITY DEFINER` function here:

- Sets `search_path = public, pg_temp` explicitly — never trusts the
  caller's search path.
- Fully re-validates every tenant relationship itself (organization ↔
  event ↔ ticket type), never trusting a caller-supplied id belongs where
  the caller claims.
- Uses no dynamic SQL (`execute format(...)`) anywhere.
- Returns a narrow, explicit column list — never `select *`, never a
  whole row type, never `checkout_token_hash`, never buyer PII beyond what
  the checkout confirmation page needs.
- Has its `EXECUTE` privilege **explicitly** revoked from `public`, `anon`,
  and `authenticated`, then **explicitly** re-granted only to the roles
  that need it — mirroring the exact two-step pattern RFC-003 discovered
  and RFC-005 reapplied: Supabase's real default privileges grant
  `EXECUTE` directly to `anon`/`authenticated` on function creation, not
  merely via implicit `PUBLIC` membership, so `revoke ... from public`
  alone is not sufficient.

**Why `get_public_ticket_availability` duplicates SQL instead of calling a
shared helper:** a shared `SECURITY DEFINER` helper that `anon` could call
directly would need its own privilege decision, and if it returned the raw
available count (rather than a boolean), it would expose more precision
than RFC-006 section 38 wants public ("`isSoldOut` may be preferable to
`availableQuantity`"). Duplicating roughly ten lines of SQL, with an
explicit comment tying the two copies together, was judged simpler and
more obviously safe than reasoning through nested-`SECURITY DEFINER`
privilege semantics for a helper only two functions would ever call.

## RLS / security model

No existing RLS policy was modified, dropped, or weakened. `orders`,
`order_items`, `ticket_holds`, and `customers` keep RFC-002's original
policies unchanged (`authenticated`/organizer-role only, zero `anon`
policies). Anonymous checkout works entirely through the three
`SECURITY DEFINER` functions above, which perform their own authorization
logic independent of RLS for their internal writes.

Verified directly (not inferred) via pgTAP:

- `anon` cannot `SELECT` any row from `orders`/`customers`/`ticket_holds`
  (`is_empty`).
- `anon` cannot `INSERT` into `orders`/`ticket_holds`/`customers` (`42501`
  via `throws_ok`).
- `function_privs_are()` asserts the exact `EXECUTE` privilege set for
  every one of the four new functions, for `anon`, `authenticated`,
  `public`, and `service_role` — 8 assertions, not an inference from
  whether a call happened to succeed or fail.

## Money

Every monetary value is an integer count of minor units end to end —
`ticket_types.unit_price_amount` (already established by RFC-004),
`order_items.unit_price_amount`/`subtotal_amount`, `orders.subtotal_amount`/
`total_amount`. `src/lib/money.ts`'s existing `formatMoney` is reused for
every display; no floating-point arithmetic appears anywhere in the
checkout path, client or server.

## Authoritative pricing

The buyer's request (`POST /api/checkout`'s body) contains **only**
`organizationSlug`, `eventSlug`, `items: [{ticketTypeId, quantity}]`, and
`buyer: {name, email}` — no price, subtotal, total, currency,
organization id, event id, fee, available quantity, expiration, or order
status field exists anywhere in the request schema
(`src/features/checkout/schemas.ts`), so there is nothing for a malicious
caller to smuggle through even by hand-crafting a request. Every price is
read from `ticket_types.unit_price_amount` **inside** the locked
validation loop; `lineTotal = unitPrice * quantity` and
`subtotal = SUM(lineTotals)` are both computed in `plpgsql`. For RFC-006,
`total = subtotal` — there are no platform billing fees yet (RFC-011).

## Transaction boundaries

Everything in `create_order_with_hold` — organization/event resolution,
every ticket type lock and validation, customer upsert, the `orders`
insert, every `order_items` insert, every `ticket_holds` insert — happens
inside the single implicit transaction of one PL/pgSQL function call.
Any `raise exception` at any point rolls back the entire call: a
structural validation failure on line 1 of the cart rolls back nothing
(nothing was written yet); an inventory failure on the last line of a
5-line cart rolls back the customer upsert and the order header that
would otherwise have been created. There is no intermediate commit inside
the function.

## API

### `POST /api/checkout`

Deliberately thin (`src/app/api/checkout/route.ts`): parse JSON → Zod
validate (`src/features/checkout/schemas.ts`) → generate + hash a checkout
token (`src/lib/checkout/token.ts`) → call `create_order_with_hold`
(`src/features/checkout/api.ts`) → map any thrown error to a stable
`CheckoutErrorCode` (`src/features/checkout/errors.ts`) → respond. No
inventory/pricing/tenant logic lives in this file.

**Request:**

```json
{
  "organizationSlug": "lucky-losers",
  "eventSlug": "lucky-losers-live",
  "items": [{ "ticketTypeId": "…uuid…", "quantity": 2 }],
  "buyer": { "name": "Juan Comprador", "email": "juan@example.com" }
}
```

**Response (201):**

```json
{
  "orderId": "…uuid…",
  "checkoutToken": "…64-hex-char raw token, shown exactly once…",
  "status": "PENDING_PAYMENT",
  "expiresAt": "2026-09-24T12:10:00.000Z",
  "currency": "ARS",
  "subtotalMinor": 4500000,
  "totalMinor": 4500000,
  "items": [
    {
      "ticketTypeId": "…uuid…",
      "name": "General",
      "quantity": 2,
      "unitPriceMinor": 1500000,
      "lineTotalMinor": 3000000
    }
  ]
}
```

Never returned: customer internal fields, `checkout_token_hash`, payment
secrets, internal organization metadata, arbitrary database rows, or any
id beyond `orderId`/`ticketTypeId`.

**Error response** (any 4xx/5xx):

```json
{
  "error": {
    "code": "INSUFFICIENT_INVENTORY",
    "message": "Not enough tickets are available for your request. Please lower the quantity."
  }
}
```

### Error model

| Code                        | HTTP | Meaning                                                                                       |
| --------------------------- | ---- | --------------------------------------------------------------------------------------------- |
| `EVENT_NOT_AVAILABLE`       | 404  | Event doesn't exist, wrong org/event slug pair, or not `PUBLISHED`                            |
| `TICKET_TYPE_NOT_AVAILABLE` | 404  | Ticket type doesn't exist, isn't `PUBLIC`/active, or belongs to a different event/org         |
| `SALES_NOT_STARTED`         | 409  | `now() < sales_start_at`                                                                      |
| `SALES_ENDED`               | 409  | `now() >= sales_end_at`                                                                       |
| `INSUFFICIENT_INVENTORY`    | 409  | Requested quantity exceeds authoritative availability                                         |
| `INVALID_QUANTITY`          | 400  | Malformed line, non-positive/duplicate quantity, or malformed request body                    |
| `ORDER_EXPIRED`             | 410  | Reserved for a future caller — never currently raised (see `src/features/checkout/errors.ts`) |
| `INVALID_CHECKOUT_TOKEN`    | 404  | Missing/wrong token, or an order id with no matching hash                                     |
| `CHECKOUT_LIMIT_EXCEEDED`   | 400  | Exceeds a ticket type's `max_per_order` or the cart-wide `MAX_TICKETS_PER_ORDER`              |

Every Postgres exception the migration raises carries a custom SQLSTATE
(`LT001`-`LT009`); `src/features/checkout/errors.ts` is the **one** place
that maps a SQLSTATE to one of the codes above — nothing else in the
checkout feature inspects a raw Postgres/PostgREST error. Any
unrecognized error becomes `UNKNOWN` (500), is logged server-side, and
never echoes the underlying message to the browser.

## UI

**Public event page**
(`src/app/e/[organizationSlug]/[eventSlug]/page.tsx`,
`src/features/checkout/components/checkout-form.tsx`, replacing RFC-005's
static, disabled `TicketTypeList`): each ticket type row now has working
`−`/`+` quantity controls (clamped to `max_per_order` and the cart-wide
`MAX_TICKETS_PER_ORDER`), shows unit price and a running per-line
subtotal, and — once at least one ticket is selected — reveals a name +
email form and a "Continue to checkout" button. Selecting quantities
writes **only** to React state; nothing is persisted until submission
(RFC-006 section 35: "NO ORDER, NO HOLD" before that point). The
displayed subtotal is explicitly an estimate for UX; the authoritative
totals come back from `POST /api/checkout`'s response and are what the
next page actually shows.

**Checkout confirmation page**
(`src/app/checkout/[orderId]/page.tsx`,
`src/features/checkout/components/{checkout-summary,checkout-countdown}.tsx`):
requires a valid `?token=`; renders event name/date/venue, every line
item, subtotal, total, currency, order status, and a live countdown
("Tu reserva vence en 09:42") computed from the authoritative
`expires_at` the server returned. The "Continuar al pago" button is
rendered **disabled** — RFC-007's job to wire up. When the countdown
reaches zero, the page calls `router.refresh()` once so the Server
Component re-fetches `get_checkout_order` and displays whatever the
database now authoritatively reports (typically `EXPIRED`); the
client-side timer itself never decides or claims that the reservation is
released — only the database's `expires_at` comparison does that.

## Testing strategy

### Database (pgTAP)

`supabase/tests/database/rfc_006_orders_inventory.test.sql` — **61**
assertions (see "Tests" below for the full list) covering function
privileges, RLS/anon table-access denial, the happy path, event-status
validation, ticket-type validation, active/expired hold semantics,
multi-line atomicity, the expiration lifecycle, and checkout token
security.

### Concurrency test (real, not simulated)

`scripts/rfc-006-concurrency-test.sh` opens two genuinely independent
`psql` connections against a running Postgres instance and launches them
concurrently (`&`/`wait`) — pgTAP cannot do this, since it runs entirely
inside one backend/one transaction. Two scenarios:

1. **Capacity=1 race**: two concurrent 1-ticket requests against a ticket
   type with exactly one unit of inventory.
2. **Deterministic lock ordering**: two concurrent multi-ticket carts
   touching the same two ticket types in opposite JSON order (`[General,
VIP]` vs. `[VIP, General]`), both with enough inventory to succeed —
   proving no deadlock regardless of request ordering.

See "Concurrency test" under "Validation results" for exact run
instructions and the actual output obtained.

### Application / pure logic

No new test runner was introduced for application code (matching RFC-005's
precedent — the project has none configured yet). The Zod schema,
`CheckoutError`/`toCheckoutError`, and `deriveTicketAvailability`
(extended, not replaced) remain pure, dependency-free functions that a
future test runner could exercise directly without rework.

## Tests

`supabase/tests/database/rfc_006_orders_inventory.test.sql` — 61 pgTAP
assertions:

**Function privileges (1-8).** `anon` has exactly `EXECUTE` on
`create_order_with_hold`; `authenticated` has `EXECUTE` on it too; the bare
`public` pseudo-role has nothing on it (rules out the implicit-grant path);
`anon` has `EXECUTE` on `get_checkout_order` and on
`get_public_ticket_availability`; `anon` and `authenticated` both have
**no** privileges on `expire_pending_orders`; `service_role` has `EXECUTE`
on it.

**RLS / anon table access (9-14).** `anon` cannot `SELECT` any row from
`orders`, `customers`, or `ticket_holds`; `anon` cannot `INSERT` into
`orders`, `ticket_holds`, or `customers` (`42501`).

**Happy path (15-27).** Checkout for a `PUBLISHED` event with valid
`PUBLIC` ticket types creates an order; status is `PENDING_PAYMENT`;
subtotal/total arithmetic is correct; a customer record is created,
organization-scoped; exactly 2 `order_items` exist for a 2-line cart;
every `unit_price_amount` was copied verbatim from `ticket_types` (never
client-supplied); every line total is `unit_price * quantity`; exactly 2
`ticket_holds` exist; each hold's quantity matches its order item's;
every hold shares the same server-generated `expires_at` as the order;
`expires_at` is ~10 minutes out, never caller-supplied; the order belongs
to the requested organization and event.

**Event validation (28-32).** A `DRAFT`, `CANCELLED`, or `ARCHIVED` event
is rejected; a nonexistent event slug is rejected with the identical
error; a published event's slug under the wrong organization is rejected.

**Ticket type validation (33-44).** An inactive ticket type is rejected; a
`HIDDEN` ticket type is rejected; a nonexistent ticket type id is
rejected; a ticket type from a different event (same org) is rejected; a
ticket type from a different organization is rejected, even by valid
UUID; a not-yet-started sales window is rejected (`SALES_NOT_STARTED`); an
ended sales window is rejected (`SALES_ENDED`); a zero quantity line is
rejected; a negative quantity line is rejected; a quantity above a ticket
type's own `max_per_order` is rejected; a cart whose total exceeds
`MAX_TICKETS_PER_ORDER` is rejected even when every individual line is
under its own `max_per_order`; duplicate ticket types in one cart are
rejected.

**Active / expired holds (45-47).** Capacity=5 with 3 already actively
held: requesting 3 more fails (`INSUFFICIENT_INVENTORY`), requesting
exactly the remaining 2 succeeds. A ticket type with 5 **expired** holds
on record still shows full availability — expired holds never consume
inventory, proven without waiting for any cleanup job.

**Multi-line atomicity (48-51).** A 2-line cart where one line has
insufficient inventory fails as a whole; the failed attempt created zero
orders, zero order_items (not even for the line that _was_ available),
and zero ticket_holds.

**Expiration lifecycle (52-56).** A sanity check that a backdated fixture
order is still `PENDING_PAYMENT` before cleanup runs (proving test 47's
availability came from timestamp math, not a status change);
`expire_pending_orders()` transitions exactly the one lapsed order;
its status is now `EXPIRED`; running the function again is idempotent
(0 additional rows); a genuinely still-valid `PENDING_PAYMENT` order is
untouched.

**Checkout token security (57-58).** The correct raw token resolves the
correct order; an invalid token for a real order id fails; an empty
token fails; the correct token paired with a different (nonexistent)
order id fails; a second order's token cannot be used to read the first
order (cross-order isolation).

**Regression baseline.** RFC-002 (22), RFC-003 (14), RFC-004 (20), and
RFC-005 (18) were re-run unchanged alongside the new suite: **135/135
pgTAP assertions pass**, verified against a from-scratch-rebuilt database.

## Manual E2E

No running Next.js dev server against a live Supabase project was
reachable from this sandbox, so the RFC's 22-step browser-driven scenario
could not be executed as a real click-through. What **was** verified
instead, against real Postgres (the local verification database, not
Supabase's CLI stack — see "Known limitations"):

- Every database-level step of that scenario (event/ticket type fixtures,
  checkout creation, order/customer/order_items/ticket_holds creation,
  authoritative totals, checkout token issuance and verification, wrong
  token rejection, order-id-alone rejection, over-capacity rejection,
  expired-hold-no-longer-consuming-inventory) is covered by the pgTAP
  suite above and by the standalone concurrency script.
- `npm run build` succeeded for real this session (see "Validation
  results"), which compiles and type-checks every new route
  (`/checkout/[orderId]`, `/api/checkout`) and component against Next.js's
  own App Router route-typing — this is stronger than prior RFC turns in
  this sandbox achieved, but it is still not the same as a human clicking
  through the actual page in a browser against live data.
- The steps this RFC could **not** perform: actually opening the public
  event page and checkout page in a browser, actually submitting the
  buyer form through the UI, and visually confirming the countdown
  timer's rendering.

## Known limitations

- **No real local Supabase/Docker-backed Postgres could be run this
  session.** See "Validation results" for the exact, honestly-reported
  chain of attempts (including a genuinely new finding this session: the
  cloud sandbox's Docker _daemon_ can now start, but pulling the
  `ghcr.io/supabase/*` images it needs is blocked by this environment's
  network egress policy — `Forbidden` on every image pull attempted). All
  database testing (pgTAP suite + the concurrency script) ran against a
  plain local PostgreSQL instance with every RFC-002 through RFC-006
  migration applied in order, plus a hand-written shim reproducing
  Supabase's `auth` schema/roles/default-privilege behavior — **not**
  `supabase db reset`/`supabase test db` themselves. This is a substitute,
  not equivalent to the real CLI-orchestrated stack, and is reported as
  such rather than claimed as "real Supabase validation."
- `next build`/`typecheck`/`lint`/`format:check` **did** run for real this
  session (a genuine improvement over prior RFC turns in this same
  sandbox, which lacked the `@next/swc-linux-*` native binary on an
  arm64 host — this session's host is x86_64 and the binary resolved
  normally). See "Validation results".
- No scheduled/cron infrastructure invokes `expire_pending_orders()` yet —
  by design (RFC-006 section 45). A `PENDING_PAYMENT` order whose hold has
  lapsed can sit with that status for an arbitrary amount of time until
  something calls the function; inventory correctness is unaffected
  either way (see "Expiration semantics").
- `ORDER_EXPIRED` is a defined `CheckoutErrorCode` with no current caller —
  reserved for RFC-007, which will need to reject a payment attempt
  against an order the countdown has already lapsed on.
- The manual E2E scenario (RFC-006 section 69) could not be run as a real
  browser-driven flow — there is no running Next.js dev server against a
  real Supabase project reachable from this sandbox. See "Manual E2E"
  below for exactly what was and wasn't exercised.

## RFC-007 integration point

RFC-006 finishes with, for a successful checkout:

- `orders.status = 'PENDING_PAYMENT'`
- Inventory temporarily reserved via `ticket_holds` (timestamp-gated, no
  cron dependency)
- `orders.checkout_token_hash` set; the buyer holds the matching raw token
- `orders.expires_at` known and authoritative

RFC-007 can safely assume all of the above and build directly on top of
it: create a Mercado Pago Checkout Pro preference for a `PENDING_PAYMENT`
order it looks up by id, redirect the buyer, receive a webhook, verify the
payment, and transition the order to `PAID` — all without needing to
change the inventory formula (the `PAID` term already exists and is
already correctly excluded from double-counting against the `PENDING_PAYMENT`
term), without needing to change the checkout token mechanism (RFC-007's
payment continuation can reuse the same token), and without needing to
touch this RFC's migration at all. RFC-006 deliberately does not
prematurely implement any part of that flow.
