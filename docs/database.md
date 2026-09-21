# Database

**Status:** RFC-002 — Database Schema & Multi-Tenant Security. This document
describes the schema, security model, and conventions established by
`supabase/migrations/20260917151637_rfc_002_initial_schema.sql`. No product
flow (checkout, payments, ticket issuance, check-in, webhooks) reads or
writes these tables yet — see "Deferred database behavior" below.

## Entity overview

```text
auth.users
    │
    ▼
profiles

organizations
    │
    ├── organization_members
    ├── payment_accounts
    ├── customers
    ├── billing_accounts
    │
    └── events
          │
          ├── ticket_types
          ├── ticket_holds
          ├── orders
          │     ├── order_items
          │     ├── payments
          │     └── tickets
          │            └── check_ins
          │
          ├── guest_lists
          │     └── guests
          │
          └── settlements
                └── settlement_items

webhook_events   (global, no organization_id)
audit_logs       (organization_id nullable)
```

All 20 tables have Row Level Security enabled. See "RLS strategy" below for
the policy on each.

## Tenant boundary

`organizations` is the tenant. Every business table hangs off it, either
directly (`organization_id references organizations(id)`) or transitively
through a parent that itself hangs off an organization. `users` are never
the tenant — a user reaches an organization only through
`organization_members`, and can belong to several.

## Money representation

Every monetary column is a `bigint` holding integer minor units (e.g. ARS
`$12,500.50` is stored as `1250050`), never `numeric`/`float`/`double
precision`. Column names are explicit about what they hold
(`unit_price_amount`, `subtotal_amount`, `service_fee_amount`,
`total_amount`, `paid_amount`, `gross_sales_amount`, `platform_fee_amount`)
— nothing is ever named just `price`, `total`, or `amount`. Currency is a
separate `char(3)` column next to every monetary value (never assumed to be
ARS), checked against `^[A-Z]{3}$` (structurally 3 characters via `char(3)`,
uppercase-letters via the regex; not validated against the full ISO 4217
list — a deferred enhancement, see below). Fee percentages
(`billing_accounts.fee_percentage_bps`) are basis points (500 = 5.00%), also
never floating point.

Two arithmetic invariants are enforced by `CHECK` constraints, not
application code: `orders.total_amount = subtotal_amount + service_fee_amount`,
and `order_items.subtotal_amount = unit_price_amount * quantity`.
`settlement_items.net_amount = gross_amount - fee_amount` similarly.

RFC-002 does not enforce that an order's currency matches its ticket types'
or its organization's default currency — multi-currency consistency across
these is deferred until a feature actually needs cross-currency handling.

## Time strategy

Every meaningful timestamp is `timestamptz`, defaulting to `now()`. An
organization's `timezone` (default `America/Argentina/Buenos_Aires`) is
presentation/business context for displaying an already-absolute instant —
it never replaces `timestamptz` storage, and event instants
(`starts_at`, `doors_open_at`, `ends_at`, sales windows) are always stored
absolute.

## Identifiers

Every primary key is `uuid default gen_random_uuid()` (built into Postgres
core since v13 — no extension required). No sequential ID is ever used as a
security token. `ticket_number` / `order_number` are human-facing reference
identifiers, not authorization — matching a ticket number grants no access
by itself. QR authorization is a strictly separate, not-yet-implemented
concept (see "QR hash storage intent" below).

## Enum strategy

PostgreSQL enums are used only where the RFC's own review confirmed a
genuinely stable, closed set of states: `organization_status`,
`organization_role`, `event_status`, `order_status`, `payment_status`,
`ticket_status`, `guest_status`, `settlement_status`, `fee_type`,
`payment_provider`, `webhook_status`, and one not explicitly named by the
RFC but needed to keep `ticket_types.visibility` from being unconstrained
free text: `ticket_visibility` (`PUBLIC` / `HIDDEN` — the smallest useful
model; a richer one is deferred until a feature needs it).

`event_status` persists lifecycle only (`DRAFT/PUBLISHED/FINISHED/
CANCELLED/ARCHIVED`). Derived concepts like `ON_SALE`, `SOLD_OUT`, or
`UPCOMING` are deliberately never stored — they're computed at query time
from `sales_start_at`/`sales_end_at`/ticket inventory, which is the only way
they can ever be correct without a synchronization mechanism.

`payment_provider` currently has one value (`MERCADO_PAGO`) despite being an
enum rather than free text, because "which providers exist" is a curated
list that drives provider-specific logic elsewhere (see ADR-005 in
`architecture.md`), not arbitrary data. Adding a provider later is an
additive `ALTER TYPE ... ADD VALUE`, which is safe and touches no existing
row.

## Deletion strategy

Two deletion behaviors are used, chosen per table by what the table means:

**`ON DELETE RESTRICT`** from every business table back to `organizations`,
and via every composite tenant-consistency foreign key (see below). An
organization (or event, order, ticket_type, ...) with any dependent data
cannot be hard-deleted — verified directly in this session (deleting an
organization with one event fails with `foreign_key_violation`). The
intended lifecycle for organizations and events is archival via `status`,
not deletion. Nothing about the schema tries to make deletion of a populated
organization "work" — that's deliberate.

**`ON DELETE CASCADE`** is used in exactly three places, each a pure,
disposable extension of its parent rather than a business/historical
record: `profiles.id → auth.users(id)`, `organization_members.organization_id
→ organizations(id)`, and `organization_members.user_id → auth.users(id)`.
Losing a profile or a membership row when the underlying account or
organization disappears is correct, not a data-loss risk.

**`ON DELETE SET NULL`** is used for "who did this" references on records
that must outlive the actor: `check_ins.checked_in_by`,
`audit_logs.organization_id`, `audit_logs.actor_user_id`. Deleting a staff
account must not delete the check-in history they created.

**No DELETE policy at all** (meaning: impossible via the client API for any
authenticated role, verified directly in this session — an order's own
OWNER cannot delete a `PAID` order) exists for `orders`, `order_items`,
`payments`, `tickets`, `check_ins`, `settlements`, `settlement_items`,
`webhook_events`, `audit_logs`, `organizations`, and `events`. Financial and
historical tables simply have no path to client-side deletion in RFC-002 —
not "restricted to admins," but entirely absent. `service_role` (which
bypasses RLS) is the only way any of these rows are ever removed, and
RFC-002 does not implement anything that does so.

## Tenant-consistency strategy

Adding an `organization_id` column to every table is not sufficient by
itself — RFC-002's explicit failure case is an `order` whose
`organization_id` says Organization A but whose `event_id` points at an
event belonging to Organization B. This is prevented **declaratively**, not
procedurally:

1. Every table that other tenant-scoped tables reference as a parent has a
   `UNIQUE (organization_id, id)` constraint in addition to its plain `id`
   primary key (`events`, `ticket_types`, `customers`, `orders`,
   `order_items`, `tickets`, `guest_lists`, `settlements`).
2. Every child table then uses a **composite foreign key**
   `FOREIGN KEY (organization_id, parent_id) REFERENCES parent(organization_id, id)`
   instead of a plain `parent_id REFERENCES parent(id)`.

The effect: Postgres itself rejects any row whose `organization_id` doesn't
match its parent's `organization_id`, at insert or update time, as a
`foreign_key_violation` (SQLSTATE `23503`) — not an application bug that
might be forgotten, a database constraint that cannot be. This is verified
directly by pgTAP test 09 (`supabase/tests/database/rfc_002_security.test.sql`):
attempting to attach a `ticket_type` in Organization A to Organization B's
event fails at the database layer.

No triggers are used for this — every RFC-002 tenant-consistency guarantee
is a declarative constraint, per the RFC's stated preference.

**Scope note:** this composite-FK treatment covers _organization_
consistency only, which is what RFC-002 section 26 asks for. A narrower,
same-organization-but-different-event inconsistency is still possible at
the schema level today — e.g. an `order_item` could in principle reference
a `ticket_type` from a different event within the _same_ organization than
its `order`. Preventing that would require denormalizing `event_id` onto
`order_items` and a further composite FK layer; it's deferred as a
documented gap (see "Deferred database behavior") rather than added
speculatively, since RFC-002's explicit example and mandate is
organization-level, not event-level, consistency.

## RLS strategy

Every table has RLS enabled with **no anonymous access anywhere** — every
policy in the migration is `to authenticated` (or has no policy at all).
Verified directly: an anonymous session sees zero rows from `events` or
`organizations` (pgTAP tests 04a/04b).

**Membership check.** `public.is_organization_member(organization_id)` and
`public.has_organization_role(organization_id, roles[])` are the two
helpers every policy is built from, both `SECURITY DEFINER` with
`search_path` pinned to `public, pg_temp` and every reference
schema-qualified — required so the functions can query
`organization_members` internally **without** re-triggering
`organization_members`'s own RLS policy, which is what avoids the classic
recursive-policy trap (RFC-002 section 32; the fix is documented at the top
of the "RLS helper functions" section of the migration and its correctness
is exercised by every test in the suite, none of which hang or recurse).

**The `organization_members` bootstrap problem.** Membership INSERT is
normally restricted to existing `OWNER`/`ADMIN` — but a brand-new
organization has zero members, so no one could ever satisfy that check for
the very first row. RFC-002 adds one narrowly-scoped policy: an
authenticated user may insert themselves as `OWNER` of an organization that
currently has _zero_ members at all. This is what makes
`organizations_insert_authenticated` (any authenticated user may create a
new, empty organization) actually usable end-to-end, and is verified by the
suite's final test. It is the one deliberately "open" policy in the schema,
and it's safe because an organization with zero members has no data to
protect yet.

**Role capability summary** (full detail in the migration's own comments):

| Table(s)                                  | OWNER      | ADMIN      | PRODUCER   | DOOR_STAFF                         | VIEWER |
| ----------------------------------------- | ---------- | ---------- | ---------- | ---------------------------------- | ------ |
| organizations, organization_members       | RW         | RW         | R          | R                                  | R      |
| events, ticket_types, guest_lists, guests | RW         | RW         | RW         | R (guests/lists), R (events/types) | R      |
| customers (audience)                      | RW         | RW         | —          | —                                  | —      |
| orders, order_items, ticket_holds         | R          | R          | R          | —                                  | R      |
| payments, settlements, settlement_items   | R          | R          | —          | —                                  | —      |
| tickets                                   | R          | R          | R          | R                                  | R      |
| check_ins                                 | R + insert | R + insert | R + insert | R + insert                         | R      |
| payment_accounts, billing_accounts        | RW         | R          | —          | —                                  | —      |

Notes on judgment calls made explicit here because the RFC intentionally
didn't over-specify them:

- **Transactional tables are read-only for every role in RFC-002**, full
  stop. `orders`, `order_items`, `payments`, `tickets`, and `ticket_holds`
  get no client-facing INSERT/UPDATE/DELETE policy at all — those rows are
  meant to be produced by commerce/service-role logic that does not exist
  until a later RFC. This is stricter than the RFC required but directly
  follows from "do not implement checkout" — opening a mutation path with
  no flow behind it would be premature.
- **OWNER vs ADMIN differ in exactly one place**: `payment_accounts` and
  `billing_accounts` are OWNER-write / ADMIN-read-only. This models
  "billing administration" (which the RFC explicitly contrasts with
  PRODUCER's scope) as an OWNER-level capability. Every other table treats
  OWNER and ADMIN identically in RFC-002.
- **`customers` (audience) is OWNER/ADMIN only** — PRODUCER, DOOR_STAFF, and
  VIEWER get no access at all, matching "audience/customer data is
  protected" and "door staff should not automatically gain access to ...
  audience."
- **DOOR_STAFF can read `tickets`, `events`, `ticket_types`, `guest_lists`,
  `guests`**, and can **insert** `check_ins` — everything needed to do a
  door job — but has zero access to `orders`, `order_items`, `payments`,
  `customers`, `billing_accounts`, `payment_accounts`, or `settlements`
  (verified by pgTAP tests 05, 06, and the bonus customers/orders
  assertions).
- **`check_ins` has no UPDATE/DELETE policy for anyone** — append-only by
  design. The one integrity guarantee RFC-002 adds ahead of the Door RFC's
  atomic check-in function is `UNIQUE(ticket_id)`: a ticket can never have
  two check-in rows, enforced by Postgres itself (verified: a second
  check-in insert for the same ticket fails with `unique_violation`).
- **`webhook_events` has zero policies** for `anon`/`authenticated` — no
  tenant column exists to scope by, and it's `service_role`-only by
  construction, not by an access rule that could be loosened by mistake.
- **`audit_logs` is readable by OWNER/ADMIN for their own organization,
  writable by no client role at all** — appending is service-role-only,
  matching "do not allow normal client users to mutate audit logs."

## Role intent

`OWNER` (full control) and `ADMIN` (most operational control, minus billing
administration) are functionally identical in RFC-002 except for
`payment_accounts`/`billing_accounts` — a finer split (e.g. only OWNER can
grant the OWNER role itself) is a reasonable future hardening step,
deliberately not built now to avoid over-specifying permissions for
features that don't exist yet. `PRODUCER` gets full event/ticket-type/guest
management plus read-only operational visibility into orders/tickets, never
audience or financial administration. `DOOR_STAFF` is scoped to exactly
what a door job needs. `VIEWER` mirrors PRODUCER's read scope with no
writes anywhere (verified: VIEWER cannot insert an event even in their own
organization).

## Indexing strategy

Every foreign key (including composite tenant-consistency FKs — Postgres
does **not** auto-index referencing columns) has a supporting index, found
by systematically cross-referencing every `FOREIGN KEY` constraint in the
migration against `pg_indexes` in this session — two composite-FK gaps
(`tickets` → `order_items`/`ticket_types`, `settlement_items` →
`ticket_types`, `ticket_holds` → `orders`) and one missing FK-backing index
on `settlements` were found this way and fixed before this migration was
finalized.

Several indexes intentionally consolidate what the RFC listed as separate
single-column indexes into one composite, because under RLS every realistic
query is already organization-scoped, making `organization_id` a near-
universal leading column: e.g. `events_org_status_idx (organization_id,
status)` serves both the RFC's suggested `events(organization_id)` and
`events(organization_id, status)` from one index (a composite index serves
prefix-only lookups on its leading columns for free), and
`ticket_types_org_event_idx (organization_id, event_id)` is used in place
of a bare `ticket_types(event_id)` because a query without `organization_id`
is not a realistic access pattern in a tenant-scoped app. Each such
deviation from the RFC's literal list is commented at its `CREATE INDEX`
site in the migration.

`payments_provider_payment_key` and `webhook_events_provider_event_key`
(both `UNIQUE(provider, provider_*_id)`) double as the idempotency
guarantee described below and as their own supporting index — no separate
index was added for either.

## Webhook idempotency

`webhook_events` has `UNIQUE(provider, provider_event_id)`. A retried or
duplicated delivery from the same provider for the same event id is a
constraint violation, not a double-processed event — this is the entire
idempotency guarantee RFC-002 provides; no webhook route exists yet to
exercise it.

## QR hash storage intent

`tickets.qr_token_hash` stores a hash only — there is no column anywhere in
this schema for a raw QR secret, by construction, not by convention. It's
nullable (ticket issuance isn't implemented yet) and unique across the
whole platform once assigned. The hashing algorithm, token format, and
issuance flow are all deferred to the ticketing RFC; RFC-002 only reserves
the column and its uniqueness guarantee.

## Deferred database behavior

Explicitly not implemented, and why:

- **Hold acquisition/release, atomic check-in, fee calculation, settlement
  generation, webhook processing** — all business flows, per RFC-002's own
  scope boundary. Only storage and constraints exist.
- **"An organization must always have at least one OWNER"** is not
  enforced. A lone OWNER can currently remove their own membership via the
  self-removal DELETE policy, leaving the organization ownerless. Enforcing
  this declaratively needs either a deferred constraint trigger or
  application-level guarding; left for a later RFC rather than adding
  procedural logic RFC-002 doesn't otherwise need.
- **Event-level (not just organization-level) tenant consistency** for
  `order_items`/`tickets` against their order's event — see the "Scope
  note" under Tenant-consistency strategy above.
- **ISO 4217 currency validation** — `currency` columns check for
  3 uppercase letters, not membership in the real currency list.
- **Fine-grained OWNER-vs-ADMIN role hierarchy** (e.g. only OWNER can grant
  OWNER) — not built; see "Role intent" above.
- **Payment credential storage** — `payment_accounts` stores connection
  metadata only. A secure, server-only strategy for OAuth tokens/secrets is
  explicitly left to the payment RFC, per RFC-002 section 21.

## Local verification environment (this session only)

This sandbox has no Docker registry access (`docker.io`, `ghcr.io`, and
`public.ecr.aws` are all blocked by the egress proxy), so
`supabase start`/`supabase test db`/`supabase gen types` — all of which
pull Docker images — could not run here. To still get real, executed
verification rather than "trust me," this session:

1. Used the plain PostgreSQL 16 already installed in the sandbox.
2. Applied a local-only shim (kept **out of this repository**, never
   shipped) that reproduces exactly the primitives RFC-002 depends on from
   a real Supabase project: the `auth` schema, `auth.users`, `auth.uid()`
   (reading the same `request.jwt.claim.sub` GUC PostgREST sets per
   request in production), and the `anon`/`authenticated`/`service_role`
   roles.
3. Applied `supabase/migrations/20260917151637_rfc_002_initial_schema.sql`
   unmodified on top of that shim, twice, on a dropped-and-recreated
   database both times, to confirm it applies cleanly and deterministically.
4. Ran `supabase/tests/database/rfc_002_security.test.sql` (real pgTAP —
   the same file `supabase test db` will run once Docker access exists)
   via `pg_prove` against that database. All 22 assertions passed.

Once Docker registry access is available (a different network policy, or a
different machine), the real commands are:

```bash
supabase start
supabase test db
supabase gen types typescript --local > src/types/database.ts
```

No hand-written stand-in for `src/types/database.ts` was created — RFC-002
section 38 is explicit that generated types must actually be generated, not
approximated.
