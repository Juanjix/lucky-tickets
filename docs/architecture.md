# Architecture

**Status:** RFC-003 — Authentication & Organizations. Sign-up/sign-in/sign-out,
organization creation and membership, tenant-scoped dashboard routing, and
server-side authorization helpers now exist — see
[docs/rfcs/RFC-003-auth-organizations.md](rfcs/RFC-003-auth-organizations.md)
for the full design. The domain schema, tenant isolation, and RLS
(RFC-002) are documented in [docs/database.md](database.md). No event
management or business flow beyond auth/tenancy exists yet. This document
describes the direction the codebase is built to grow into, and the
conventions already in force.

## Product architecture

Lucky Ticket is a multi-tenant platform for independent event organizers. The
tenant is an **Organization**, not a User. The long-term core domain chain is:

```text
User
  → Organization Membership
    → Organization
      → Event
        → Order
          → Payment
        → Ticket
          → Check-in
```

An Organization also owns two side chains that stay decoupled from the core
sales flow so they can evolve independently:

```text
Organization → Audience   (customer/attendee database, built from Orders)
Organization → Billing    (platform fees, invoicing, settlements)
```

These tables now exist as migrations (`supabase/migrations/`), with Row
Level Security enforcing tenant isolation at the database level — see
[docs/database.md](database.md) for the full schema, RLS strategy, and
decision log. RFC-003 is the first application code to actually query
them: authentication, organization creation/membership, and tenant-scoped
dashboard routing — see
[docs/rfcs/RFC-003-auth-organizations.md](rfcs/RFC-003-auth-organizations.md).
Event management and everything past auth/tenancy still queries nothing.

## Architectural principles

**Multi-tenancy.** Every domain table introduced from RFC-002 onward hangs
off `Organization`, and every query is scoped to the caller's organization —
enforced by Postgres Row Level Security (RLS), not by application code
remembering to filter. Application code is a second line of defense, not the
first.

**Server-authoritative operations.** The browser is never trusted for prices,
availability, payment state, permissions, ticket validity, check-in state, or
billing math. Those computations happen in Server Actions, Route Handlers, or
the database itself; the client only renders what the server returns.

**Domain separation.** Order, Payment, Ticket, Check-in, and Billing are
separate concerns even though they're causally related (an Order leads to a
Payment leads to Tickets). They will live as separate tables and separate
`features/*` modules so that, for example, a change to how check-ins work
can't accidentally alter payment state.

**Provider abstraction.** External services are wrapped behind an interface
owned by this codebase, not called directly from feature code. The shape to
follow, once a real provider is introduced:

```text
PaymentGateway (interface, owned by us)
  └── MercadoPagoGateway (implementation, in services/)
```

The same applies to email, storage, and analytics providers when they
arrive. Feature code depends on the interface; only one adapter module
depends on the vendor SDK.

**RLS.** Postgres Row Level Security is the source of truth for "can this
request see or change this row," scoped by organization membership.
Introduced in RFC-002 alongside the schema it protects.

**Idempotency for future financial operations.** Payment webhooks and any
operation that moves money will be designed to be safely retried (an
idempotency key per operation) once they exist — noted here so the schema in
RFC-002 can accommodate it, not implemented now.

**Mobile-first operational UI.** The dashboard (door check-in, guest lists,
live sales) is used from phones during live events. When the dashboard is
built, layouts start at phone width and scale up, not the reverse.

**Business logic outside components.** React components handle presentation
and interaction. Domain rules, validation, and side effects live in
`features/*`, `services/`, `lib/`, and server-side functions — never
hardcoded into a component tree.

## Directory responsibilities

```text
src/
├── app/          Routing, layouts, pages, Route Handlers (App Router).
├── components/
│   └── ui/       Reusable, presentation-only primitives. No business logic.
├── features/     Business capabilities grouped by domain. `auth/` and
│                 `organizations/` exist as of RFC-003 (schemas, Server
│                 Actions, components, and — for organizations — a
│                 `server/` subfolder for RLS-backed read helpers). `events/`
│                 exists as of RFC-004 (schemas, Server Actions, components,
│                 `queries.ts`, `permissions.ts`, and `publish-rules.ts` —
│                 the centralized publication invariants RFC-005/RFC-006
│                 reuse). `events/public/` exists as of RFC-005: a
│                 deliberately separate read boundary (`queries.ts`,
│                 `types.ts`, `availability.ts`, `format.ts`, `components/`)
│                 for the anonymous buyer-facing page — its DTOs are never
│                 the organizer-facing `Tables<"events">` row type, and its
│                 one exported query (`getPublicEvent`) is the only thing
│                 allowed to use `lib/supabase/public.ts`. Ticketing,
│                 checkout, etc. arrive with the RFCs that need them.
├── lib/          Infrastructure and framework integration.
│   ├── env/      Zod-validated environment access, split public/server.
│   ├── supabase/ SSR-safe Supabase client factories + session refresh, plus
│   │             (RFC-005) `public.ts` — a cookie-less client that always
│   │             authenticates as `anon`, for the one public route.
│   ├── money.ts  Integer-minor-units helpers (RFC-004) — shared by the
│   │             organizer dashboard and the public page.
│   └── errors/   Shared AppError model (see below).
├── services/     Cross-cutting, provider-facing services (e.g. a future
│                 PaymentGateway implementation). Empty until a provider
│                 is introduced.
├── types/        Truly shared TypeScript types used across features.
│                 Empty until something is actually shared.
└── config/       App-level, non-secret configuration (e.g. site identity).
```

`lib/auth/` exists as of RFC-003: `require-user.ts`
(`requireUser`/`getOptionalUser`), `require-organization.ts`
(`requireOrganizationMembership`/`requireOrganizationRole`), and
`auth-errors.ts` (mapping Supabase auth errors to safe user-facing
messages). These are the one way application code establishes identity and
tenant authorization — see
[docs/rfcs/RFC-003-auth-organizations.md](rfcs/RFC-003-auth-organizations.md).

`lib/validation/` is still intentionally not created — RFC-003's Zod
schemas live next to the feature that owns them
(`features/auth/schemas.ts`, `features/organizations/schemas.ts`) because
nothing yet needs schema conventions shared _across_ features. When
something does, `lib/validation/` holds that shared convention; each trust
boundary (a form, a Route Handler, a webhook payload, a query parameter)
validates its own input with Zod regardless — TypeScript types are
compile-time only and do not substitute for runtime validation.

`dashboard/[organizationSlug]/` exists as of RFC-003 — every tenant-scoped
route lives under it, resolved and authorized by that segment's `layout.tsx`
(see the RFC-003 doc's "Tenant resolution"). `login/`, `signup/`, and
`onboarding/` are top-level routes, not grouped, since there's no shared
layout need yet beyond the root one. `e/[organizationSlug]/[eventSlug]/`
exists as of RFC-005 — the one public, unauthenticated route, deliberately
outside `dashboard/` (no session/tenant resolution applies to it, and
never will) and given its own short top-level segment rather than a
`(public)` route group, since it is the only public route today and a
group with one member buys nothing yet. Conceptual route groups —
`(marketing)`, `api` — remain planned but not created as empty folders;
they appear when the first route in each actually needs one, per Next.js
App Router route group conventions.

## Dependency rule

```text
UI (app/, components/)
  ↓
Feature / application layer (features/)
  ↓
Domain / service logic (services/, lib/)
  ↓
Infrastructure / providers (Supabase, future payment/email SDKs)
```

Dependencies point downward only. A provider SDK (Supabase, and later
Mercado Pago, an email provider, etc.) is never imported directly from
`app/` or `features/` — it's reached through the `lib/` or `services/`
module that wraps it. This is what keeps a provider swap a localized change.

## Server/client boundaries

Server Components are the default. `"use client"` is added only where
browser APIs, local interactive state, effects, or a client-only library
require it — not by convention or convenience.

`src/lib/env/server.ts` and `src/lib/supabase/server.ts` import the
`server-only` package, so importing either from a Client Component fails
the build instead of silently shipping server code (or a future secret) to
the browser. `src/lib/env/client.ts` is the only place `NEXT_PUBLIC_*`
values are read, and only those two files exist for environment access —
feature code imports from them rather than reading `process.env` directly.

## Supabase foundation

Two client factories, following the current official `@supabase/ssr`
pattern for Next.js App Router (verified against the installed `@supabase/ssr`
0.12.7 types, since this API has changed across versions):

- `src/lib/supabase/client.ts` — `createBrowserClient` for Client Components.
- `src/lib/supabase/server.ts` — `createServerClient` for Server Components,
  Server Actions, and Route Handlers, reading/writing cookies via
  `next/headers`. Create a new instance per request; never share one.
- `src/lib/supabase/proxy.ts` + `src/proxy.ts` — refreshes the auth session
  on every request per Next.js's Proxy convention (the file Next.js 16
  renamed from `middleware.ts`). This is token refresh only — it does not
  redirect unauthenticated users or check permissions. Per Next.js's own
  guidance, a Proxy matcher can silently stop covering a route (e.g. a
  Server Action moved to a different path), so real authorization must be
  re-verified inside each Server Action / Route Handler regardless of
  Proxy having run.

As of RFC-003, both factories are parameterized with the generated
`Database` type (`createBrowserClient<Database>`, `createServerClient<Database>` —
see `src/types/database.ts`), so every `.from()`/`.rpc()` call is checked
against the real schema. This is a completion of the existing abstraction,
not a replacement of it: the factories, their signatures, and their
call sites are otherwise unchanged from RFC-001.

Authentication and tenant-scoped authorization are built on top of these
same two factories — `src/lib/auth/require-user.ts` and
`require-organization.ts` — rather than a second client or a different
session mechanism. See
[docs/rfcs/RFC-003-auth-organizations.md](rfcs/RFC-003-auth-organizations.md)
"Authorization helpers".

### Lazy env validation

`getClientEnv()` / `getServerEnv()` (in `src/lib/env/`) validate on call, not
on import — importing either module doesn't itself require configuration.
This matters because `src/proxy.ts` runs on nearly every request: it calls
`isServerEnvConfigured()` first and, when Supabase hasn't been configured
yet, skips session refresh and lets the request through rather than
crashing every page in the app (there's no auth flow yet for it to
protect). `lib/supabase/client.ts` and `server.ts` still call the throwing
`get*Env()` the moment something actually tries to construct a Supabase
client without configuration, so misconfiguration is never silent — it
just isn't fatal for parts of the app that don't need Supabase.

### Environment variables

| Variable                               | Exposure | Purpose                                             |
| -------------------------------------- | -------- | --------------------------------------------------- |
| `NEXT_PUBLIC_SUPABASE_URL`             | Public   | Supabase project URL                                |
| `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` | Public   | Publishable API key (RLS-protected, safe to expose) |

**Naming decision:** Supabase's current documentation (checked live, since
this key has been renamed before) uses `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY`
in place of the older `NEXT_PUBLIC_SUPABASE_ANON_KEY`. This codebase follows
that current convention — see ADR-006.

Future server-only secrets (a service-role key, a payment provider's API
key) are added to `src/lib/env/server.ts` and `.env.example`, unprefixed,
never to `client.ts`.

## Error handling convention

`src/lib/errors/app-error.ts` defines `AppError`, a small typed wrapper
distinguishing `validation | authentication | authorization | not_found |
conflict | external_provider | internal`, each with a default HTTP status
and a `publicMessage` getter that never leaks internal detail for the two
kinds (`external_provider`, `internal`) where the real message might
describe internal state. This is a convention for later Route Handlers and
Server Actions to adopt — no business error is thrown anywhere yet.

## Decision log (ADRs)

**ADR-001: Next.js App Router.** Chosen for co-located Server Components,
Route Handlers, and the Proxy convention this project relies on for
session refresh. Alternative considered: Pages Router — rejected, it's the
legacy model for new Next.js projects.

**ADR-002: Supabase as database/auth platform.** Gives Postgres, RLS,
and auth in one product, which fits the "RLS as source of truth for
tenant isolation" principle directly instead of building it from scratch.

**ADR-003: Organization-based multi-tenancy.** The tenant is `Organization`,
not `User`, because a person can belong to more than one producer/venue and
permissions are scoped per-organization, not per-account.

**ADR-004: Server-authoritative business operations.** Ticketing handles
money and access control; client-computed prices, availability, or
permissions are trivially spoofable, so every sensitive computation is
re-derived server-side.

**ADR-005: Provider abstraction.** Payment, email, storage, and analytics
providers are wrapped behind an interface owned by this codebase (see
`services/`) so a provider swap doesn't ripple through feature code, and so
integration tests can substitute a fake implementation later.

**ADR-006: `NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY` over `..._ANON_KEY`.**
Supabase's current documentation names the public client key
`PUBLISHABLE_KEY`. This project uses that name rather than the older
`ANON_KEY` convention some existing tutorials still reference, to match
what Supabase actually issues today.

**ADR-007: Proxy (`src/proxy.ts`) instead of `middleware.ts`.** Next.js 16
deprecated and renamed the middleware file convention to `proxy.ts`,
exporting `proxy` instead of `middleware`. This project targets Next.js 16
and uses the current name.

**ADR-008: Authorization lives in Server Components/Actions, not the
Proxy.** RFC-003 added `requireUser`/`requireOrganizationMembership`/
`requireOrganizationRole`, called directly from every protected route and
action, rather than extending `src/proxy.ts` to redirect unauthenticated or
unauthorized requests. Keeps exactly one place authorization logic can
live, consistent with `src/lib/supabase/proxy.ts`'s own pre-existing
comment that a Proxy matcher can silently stop covering a route and real
authorization must be re-verified per Server Action/Route Handler
regardless. A second, proxy-level check would be redundant at best and a
second place to fall out of sync at worst.

**ADR-009: Atomic organization creation via a `SECURITY INVOKER` RPC, not
two client-side inserts.** See
[docs/rfcs/RFC-003-auth-organizations.md](rfcs/RFC-003-auth-organizations.md)
"Organization creation" for the full reasoning: two separate PostgREST
calls cannot be made atomic from the client, and a partially-failed
organization-without-owner is unrecoverable under RFC-002's own RLS
policies. `SECURITY INVOKER` (not `DEFINER`) means the function still runs
under the caller's RLS rather than bypassing it.

**ADR-010: 404, not 403, for both "no such organization" and "not a
member."** `requireOrganizationMembership` deliberately can't distinguish
these two cases to the client, extending RFC-002's tenant-invisibility
guarantee (docs/database.md "Tenant boundary") to the application/routing
layer. A 403 would itself confirm a slug belongs to a real organization.

**ADR-011: cross-table integrity invariants (RFC-004) are triggers, not
application-only checks.** "Ticket inventory must not exceed event
capacity" and "a published event must have a venue and a sellable ticket
type" each span two tables, so neither can be a single-table `CHECK`
constraint — but both are still real data integrity rules, not just UX
validation, so RFC-004 added two narrowly-scoped `SECURITY INVOKER`
trigger functions (see
[docs/rfcs/RFC-004-events-ticket-types.md](rfcs/RFC-004-events-ticket-types.md)
"Event capacity" / "Event publication") rather than relying solely on the
matching TypeScript checks in `src/features/events/publish-rules.ts`. This
extends ADR-008/ADR-009's existing pattern (RLS/database backstop plus an
independent application-level check, neither one trusted alone) to
non-authorization data integrity, and deliberately stops at two small
triggers rather than a general-purpose constraint or workflow framework.

**ADR-012: the public event page uses a cookie-less, always-`anon`
Supabase client, not the visitor's own session.** RFC-005 needed a way for
an anonymous visitor to read published event data without weakening
`authenticated`'s existing RLS policies or reaching for the service-role
key. The alternative to `lib/supabase/public.ts` — reusing
`lib/supabase/server.ts` (which forwards the visitor's cookies) and adding
`to authenticated` policies alongside the new `to anon` ones — would have
made "the public boundary" depend on browser login state: a logged-in
organizer from an unrelated organization would see the page through a
different, wider policy than an anonymous visitor sees it through, and
every future public-data decision would need to consider both roles
instead of one. Building the public route on a client that never carries
a session keeps the boundary a single Postgres role (`anon`) to grant
access to, reason about, and test (see
[docs/rfcs/RFC-005-public-event-page.md](rfcs/RFC-005-public-event-page.md)
"RLS / database strategy") — it also means the page renders identically
for every visitor, which is the actual product requirement ("No login
should be required for the public route").

**ADR-013: anonymous checkout writes go through `SECURITY DEFINER`
functions, not new RLS policies.** RFC-006 needed anonymous visitors to be
able to create `orders`/`order_items`/`ticket_holds`/`customers` rows
without weakening RFC-002's existing `authenticated`-only policies on
those tables. RLS policies are evaluated per-row, not per-transaction, so
they cannot express "lock this ticket_types row, recompute availability
under that lock, and only then allow this INSERT as part of one atomic
unit" — two separate PostgREST requests hitting separate INSERT policies
could always race and reintroduce the overselling bug the RFC exists to
prevent. `create_order_with_hold`, `get_checkout_order`, and
`get_public_ticket_availability` (all `SECURITY DEFINER`, all with
explicitly revoked-then-re-granted `EXECUTE` privileges, per RFC-003's
established privilege-grant pattern) are instead the entire anonymous
write/read surface for commerce data — see
[docs/rfcs/RFC-006-orders-inventory.md](rfcs/RFC-006-orders-inventory.md)
"Public API boundary" for the full reasoning and the concurrency proof
this design enables.

**ADR-014: an order can only reach `PAID` through a `service_role`-only,
provider-verified, atomic function — never through the browser redirect or
the webhook body.** RFC-007 needed to turn a `PENDING_PAYMENT` order into
`PAID` in response to a Mercado Pago payment, without ever trusting the
buyer's own browser (the redirect back from Checkout Pro is presentation
only, and its query parameters are attacker-controllable) or the webhook
request body (an unauthenticated `POST` could otherwise claim any
`data.id`/status it likes). The alternative — validating the webhook
signature and updating `orders.status` directly from a Route Handler using
the ordinary `anon`/`authenticated` client — would have meant either
opening an RLS `UPDATE` policy that any authenticated request could
theoretically reach, or duplicating RFC-006's `create_order_with_hold`
precedent of keeping the entire write surface behind `SECURITY DEFINER`
functions with an explicit privilege grant. RFC-007 follows that existing
precedent instead: `confirm_order_payment` is granted to `service_role`
only (unreachable by `anon`/`authenticated`, even an organization's own
`OWNER` — see
[docs/rfcs/RFC-007-mercado-pago-payments.md](rfcs/RFC-007-mercado-pago-payments.md)
"RLS / security"), is the only code path that can ever write
`orders.status = 'PAID'` (there is still no client-facing `UPDATE` policy
on `orders` at all, extending ADR-013's "no direct writes" boundary to
payment state), and only runs after the webhook's `x-signature` has been
verified and the payment has been independently re-fetched from Mercado
Pago's own `GET /v1/payments/:id` — the webhook body itself is discarded
after providing the resource id. This makes "the browser cannot mark an
order paid" a database privilege fact, not an application convention,
exactly as ADR-013 made "the browser cannot oversell inventory" a database
fact rather than a UI rule.

**ADR-015: payment/webhook credentials live in a separate, lazily-loaded
env schema, not `getServerEnv()`.** `src/lib/env/server.ts`'s existing
`getServerEnv()`/`isServerEnvConfigured()` are called by `src/proxy.ts` on
every request to decide whether to attempt a Supabase session refresh —
folding `MERCADO_PAGO_ACCESS_TOKEN`/`MERCADO_PAGO_WEBHOOK_SECRET` into that
same schema would have made any environment missing a Mercado Pago
credential fail on every single request, including ones that never touch
payments at all (the public event page, the organizer dashboard, `npm run
build` itself). RFC-007 instead added a second schema,
`paymentServerEnvSchema`/`getPaymentServerEnv()`, called only from the
specific preference-creation and webhook code paths that actually need a
Mercado Pago credential — extending ADR-005's provider-abstraction
principle to environment validation itself: a provider's configuration
should fail only the requests that use that provider, not every request in
the application.

**ADR-016: ticket issuance runs inside `confirm_order_payment`'s own transaction, isolated by an exception-swallowing wrapper — not a trigger or an outbox.** RFC-008 needed "an order reaches `PAID`" to always imply "its tickets exist," with no window where the two could disagree even under a process crash between two statements. Three shapes were considered: (A) call issuance from inside `confirm_order_payment`'s existing transaction; (B) an `AFTER UPDATE` trigger on `orders`; (C) an outbox/job table drained by a separate worker. (B) and (C) both introduce a second moving part — a trigger that must be kept in lock-step with every future `orders.status` mutation path, or a queue/worker this project has no other use for — to solve something one transaction already solves for free: `confirm_order_payment` (as re-verified fresh against its live source before RFC-008 was implemented) has exactly one `update orders set status = 'PAID'` statement, reached through a single code path. (A) was chosen: `issue_tickets_for_order_safe` is called immediately after that statement, wrapped in its own `begin ... exception when others` block (an implicit `plpgsql` savepoint), so a bug in ticket issuance can never roll back a genuine payment confirmation — it can only fail to issue tickets for that one call, recorded as a `tickets_issuance_failed` `audit_logs` row for operator diagnosis (see RFC-008's own migration header and [docs/rfcs/RFC-008-ticketing.md](rfcs/RFC-008-ticketing.md) "Payment → issuance integration"). This extends ADR-014's "payment truth is a database privilege fact" with "payment truth can never regress because of an unrelated subsystem's bug." **Addendum, after a real Supabase run surfaced the gap this alone leaves open:** exception isolation protects invariant A (a payment confirmation is never lost to an issuance bug) but says nothing about invariant B (a `PAID` order can never silently stay at zero tickets forever) — a real `npx supabase test db` run against an actual local Supabase stack hit exactly this, when `gen_random_bytes` was unreachable from this migration's `search_path` (see RFC-008's "Validation results"), and the resulting issuance failure was swallowed exactly as designed, leaving a `PAID` order with zero tickets discoverable only by grepping `audit_logs`. Rather than remove the exception isolation (which would reopen invariant A), a separate, additive `reconcile_missing_tickets` function was added: `service_role`-only, no new infrastructure (no queue, no worker, no Kafka/Redis), it scans for any `PAID`/`REFUNDED`/`PARTIALLY_REFUNDED` order whose ticket count is short of its `order_items` quantity and retries issuance per order inside its own exception block, so one order's failure can never block another's recovery. It is callable on demand today; wiring it to a schedule is a follow-up once there is operational signal for how often issuance actually fails.

**ADR-017: a ticket's QR secret is stored as a one-way hash (scan-time validation) _and_ a symmetrically-encrypted ciphertext (buyer redisplay), with the encryption key passed only as a per-call argument, never persisted.** A raw QR secret can never be stored in plaintext, but a bare hash cannot be reversed to redisplay the QR to a buyer who reopens their tickets page later — RFC-008's central design problem. The migration stores both derived values on every `tickets` row: `qr_token_hash` (`sha256`, the existing RFC-002 column, for RFC-009's fast one-way scan-time lookup) and a new `qr_secret_ciphertext` (`pgcrypto`'s `pgp_sym_encrypt(raw_token, key, 'cipher-algo=aes256')`, for on-demand decryption when the buyer's already-authorized request needs to render the QR again). The encryption key (`QR_ENCRYPTION_KEY`, validated by `getTicketServerEnv()`) is never written to any table, column, Postgres setting, or log — it exists only as a plain argument to `issue_tickets_for_order`/`get_order_tickets` for the duration of that one call, so a database leak alone yields ciphertext and a one-way hash but never a usable raw secret. Generating the secret with `pgcrypto`'s `gen_random_bytes` (rather than Node's `crypto.randomBytes`) and encrypting it with `pgp_sym_encrypt` (rather than a hand-rolled AES-256-GCM module) were both deliberate: both need to run inside the same atomic, concurrency-safe `INSERT` as everything else in ADR-016's single-transaction design, and `pgp_sym_encrypt` is a mature primitive already bundled with the `pgcrypto` extension this schema already depends on for `gen_random_uuid()`. `pgp_sym_encrypt` is not an authenticated (AEAD) cipher, unlike AES-GCM — accepted because this design never decrypts attacker-supplied ciphertext, only ciphertext the issuing server itself wrote and is reading back for an already-authorized ticket row, which is exactly the case where AEAD's tamper-detection buys little. `qr_secret_version` is carried on every row from day one specifically so a future move to per-value AEAD or KMS-backed envelope encryption is a new code path distinguishable by version, not a backfill. See [docs/rfcs/RFC-008-ticketing.md](rfcs/RFC-008-ticketing.md) "QR secret design" for the full threat-model writeup.

**ADR-018: the buyer's tickets-page capability is a new, stateless, server-only value — never a reuse of RFC-006/007's checkout token.** RFC-007's own preference-creation code (`src/features/payments/api.ts`) already documents, as an accepted tradeoff, that the raw checkout token travels inside Mercado Pago's `back_urls` and is therefore retained by a third party. That exposure is acceptable for a short-lived "check my payment status" credential; it is not acceptable for a long-lived credential that unlocks scannable venue-entry QR codes, so RFC-008 mints a distinct capability instead. It is a stateless `hmac-sha256(TICKET_ACCESS_SIGNING_KEY, "order:" + orderId)`, computed in `src/lib/tickets/access-token.ts`, rather than a stored random token — a stored-token design was rejected because the webhook handler that would need to mint it has no channel back to the buyer's browser, creating an unrecoverable-lockout race (only the first process to successfully mint and deliver it could ever hand it out). Being a deterministic function of a fixed server secret and the order id, it needs no database storage, no minting endpoint, and no race: any trusted request — the payment-status poll that first observes `PAID`, or the buyer reopening the link a week later — independently recomputes and verifies the same value via `crypto.timingSafeEqual`. It is delivered by extending the _existing_ `GET /api/orders/[orderId]/payment-status` response (`src/features/payments/queries.ts`) rather than a new endpoint, matching ADR-014/RFC-007's own "reuse existing infrastructure, minimize public surface" precedent. The database-side read it gates, `get_order_tickets`, is granted to `service_role` only — exactly `confirm_order_payment`'s trust shape (ADR-014) applied to a read: the capability is verified once, in Node, before the database is ever touched, and the database's own grant is what makes that the _only_ path capable of reaching ticket data at all.
