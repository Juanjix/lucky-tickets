# Lucky Ticket

Ticketera local para bandas y productores — a multi-tenant platform for
independent event organizers, producers, bands, and venues. Ticketing is the
first module of a longer-term "operating system for independent events"
(check-in, guest lists, audience database, billing, and more, added
incrementally).

**Current implementation stage: RFC-005 — Public Event Page**

RFC-001 established the technical foundation (Next.js, Supabase client
plumbing). RFC-002 added the full database schema, tenant isolation, and Row
Level Security as Supabase migrations. RFC-003 added authentication
(sign-up/sign-in/sign-out), organization creation, multi-organization
membership, and tenant-scoped dashboard routing. RFC-004 added event and
ticket type management for organizers. RFC-005 adds the first public,
unauthenticated, buyer-facing page — an anonymous visitor can view a
PUBLISHED event and its public ticket types at `/e/[organizationSlug]/[eventSlug]`,
through a dedicated public read boundary rather than by relaxing the
organizer-facing RLS policies. See [docs/architecture.md](docs/architecture.md)
for the application architecture, [docs/database.md](docs/database.md) for
the database design, security model, and decision log, and
[docs/rfcs/RFC-005-public-event-page.md](docs/rfcs/RFC-005-public-event-page.md)
for the public page design.

## Stack

- [Next.js](https://nextjs.org) (App Router) + [React](https://react.dev) + [TypeScript](https://www.typescriptlang.org)
- [Tailwind CSS](https://tailwindcss.com)
- [Supabase](https://supabase.com) (Postgres, Auth, RLS) — CLI project in `supabase/`
- [Zod](https://zod.dev) for runtime validation at trust boundaries
- [React Hook Form](https://react-hook-form.com) + [`@hookform/resolvers`](https://github.com/react-hook-form/resolvers)
- ESLint + Prettier

## Prerequisites

- Node.js 20+ (built and tested with Node 22)
- npm
- A Supabase project (free tier is fine) if you want the app to actually
  connect to a database — the app itself doesn't require one to run
  `dev`/`build`, since no page reads Supabase yet.
- [Docker](https://docs.docker.com/get-docker/) + the
  [Supabase CLI](https://supabase.com/docs/guides/local-development) (`npx
supabase ...`, no global install needed) to run migrations and tests
  locally.

## Local setup

```bash
npm install
cp .env.example .env.local
# fill in NEXT_PUBLIC_SUPABASE_URL and NEXT_PUBLIC_SUPABASE_PUBLISHABLE_KEY
# in .env.local from your Supabase project settings
npm run dev
```

Open [http://localhost:3000](http://localhost:3000).

## Database

Schema lives in `supabase/migrations/` (Supabase CLI project, `supabase/config.toml`).
With Docker running:

```bash
npx supabase start      # local Postgres + Auth + Studio, applies migrations
npx supabase test db    # runs the pgTAP suite (74 assertions: RFC-002 + RFC-003 + RFC-004 + RFC-005)
npx supabase gen types typescript --local > src/types/database.ts
```

See [docs/database.md](docs/database.md) for the RFC-002 schema,
tenant-isolation strategy, and RLS policies; see
[docs/rfcs/RFC-003-auth-organizations.md](docs/rfcs/RFC-003-auth-organizations.md)
for the `create_organization` migration RFC-003 adds on top, and how both
were verified in an environment without Docker registry access.

## Environment variables

See [`.env.example`](.env.example) for the full list with comments. Public
(`NEXT_PUBLIC_*`) and server-only variables are validated separately at
startup — see `src/lib/env/`.

## Commands

| Command                | Purpose                           |
| ---------------------- | --------------------------------- |
| `npm run dev`          | Start the dev server              |
| `npm run build`        | Production build                  |
| `npm run start`        | Run a production build            |
| `npm run lint`         | ESLint                            |
| `npm run typecheck`    | `tsc --noEmit`                    |
| `npm run format`       | Prettier, write mode              |
| `npm run format:check` | Prettier, check mode (used in CI) |

## Directory structure

```text
src/
├── app/          Routing, layouts, pages, Route Handlers
├── components/ui/ Reusable presentation primitives (none yet)
├── features/     Business capabilities by domain (none yet)
├── lib/          Infrastructure: env validation, Supabase clients, errors
├── services/     Provider-facing services (none yet)
├── types/        Truly shared TypeScript types (none yet)
├── config/       App-level, non-secret configuration
└── proxy.ts      Refreshes the Supabase session on every request
```

Full rationale, the multi-tenancy model, and the decision log are in
[docs/architecture.md](docs/architecture.md).

## What RFC-001 includes

- Next.js App Router project (TypeScript, Tailwind, ESLint, `src/`, `@/*`)
- Supabase browser + server client factories, following the current
  official `@supabase/ssr` pattern (session refresh via `src/proxy.ts`)
- Zod-validated environment configuration, split public/server, with a
  documented `.env.example`
- A shared `AppError` convention for future error handling
- Prettier + ESLint configured and passing
- This architecture documentation

## What RFC-001 intentionally does NOT include

No business schema, no `Organization`/`Event`/`Order`/`Ticket` tables, no
RLS policies, no authentication UI, no checkout, no payments (Mercado
Pago or otherwise), no webhooks, no QR/ticket generation, no check-in, no
guest lists, no audience database, no billing, no promoters, no
merchandising, no analytics, no email delivery. These arrive incrementally
in RFC-002 and beyond.

## What RFC-002 includes

- Full domain schema as Supabase migrations (organizations, membership,
  events, ticket types, customers, orders, tickets, check-ins, guest lists,
  payment/billing accounts, settlements, webhook events, audit logs)
- Multi-tenant isolation enforced declaratively (composite foreign keys),
  not just by convention
- Row Level Security on every table, with no anonymous access anywhere
- Integer-minor-units money throughout, arithmetic invariants as `CHECK`
  constraints
- A pgTAP security/integrity test suite (`supabase/tests/database/`)
  covering all 10 required RFC-002 test cases plus role-matrix coverage
- [docs/database.md](docs/database.md)

## What RFC-002 intentionally does NOT include

No auth UI, signup/login flow, organization or event CRUD UI, public event
pages, checkout, Mercado Pago or any payment integration, webhook HTTP
routes, ticket issuance, QR generation/scanning, the atomic door check-in
function, emails, guest-list/audience UI, billing calculation, or
settlement generation. Only database primitives exist — no product flow
reads or writes these tables yet.

## What RFC-003 includes

- Email/password sign-up, sign-in, and sign-out via Supabase Auth, using
  the RFC-001 `@supabase/ssr` client factories (now typed with the
  generated `Database` type)
- Organization creation with atomic OWNER provisioning, via a new
  `create_organization` database function/migration
- Multi-organization membership and a routing-only organization switcher
- Tenant-scoped `/dashboard/[organizationSlug]` routes, protected by
  reusable server-side authorization helpers (`requireUser`,
  `requireOrganizationMembership`, `requireOrganizationRole`) backed by
  RFC-002's RLS as the final boundary
- A deterministic redirect map (unauthenticated → login, authenticated
  without an organization → onboarding, etc.) with no redirect loops
- 14 new pgTAP assertions covering the new migration (36 total with
  RFC-002) — updated from the original 11/33 after a real
  `npx supabase test db` run caught a privilege-grant issue the local
  sandbox substitute had missed; see
  [docs/rfcs/RFC-003-auth-organizations.md](docs/rfcs/RFC-003-auth-organizations.md)
  "Validation" for the full incident
- [docs/rfcs/RFC-003-auth-organizations.md](docs/rfcs/RFC-003-auth-organizations.md)

## What RFC-003 intentionally does NOT include

No event management, ticket types, checkout, Mercado Pago, orders, tickets,
QR generation, door/check-in, guest lists, billing, email delivery, merch,
promoters, analytics, OAuth providers, invitations, or team-member-management
UI. Those arrive in RFC-004 and later.

## What RFC-004 includes

- Event creation (name + start date), editing (venue, description, end
  date, capacity), and DRAFT → PUBLISHED publication, all under
  `/dashboard/[organizationSlug]/events`
- Ticket type management (create/edit/remove) per event, with money in
  integer minor units (`src/lib/money.ts`) and organization-scoped
  currency
- Two new database triggers enforcing cross-table invariants a `CHECK`
  constraint can't express: ticket inventory vs. event capacity, and
  publication requirements (venue + at least one sellable ticket type) —
  no new table or column
- Reuses RFC-002's existing `events`/`ticket_types` schema and RLS
  policies, and RFC-003's `requireOrganizationRole`, unchanged
- 20 new pgTAP assertions covering the new migration (56 total with
  RFC-002/RFC-003)
- [docs/rfcs/RFC-004-events-ticket-types.md](docs/rfcs/RFC-004-events-ticket-types.md)

## What RFC-004 intentionally does NOT include

No public event page, public event discovery, checkout, Mercado Pago,
payment webhooks, orders, order items, ticket issuance, QR codes,
check-in, guest lists, billing, settlements, promoters, merchandising,
audience CRM, email campaigns, advanced analytics, discount codes, ticket
transfer/resale, seat maps, or native applications. Those arrive in
RFC-005 and later.

## What RFC-005 includes

- The first public, unauthenticated, buyer-facing page:
  `/e/[organizationSlug]/[eventSlug]` (a Server Component, no
  `/dashboard/...` route, no event UUIDs in the URL)
- A dedicated public read boundary (`src/features/events/public/`) that
  maps database rows to a narrow `PublicEventPage` DTO — never the
  organizer's internal `Tables<"events">` shape — showing only
  organization name/slug/timezone, event name/description/venue/address/
  dates, and PUBLIC, active, in-stock ticket types with buyer-facing
  availability (UPCOMING / AVAILABLE / ENDED) derived from
  `sales_start_at`/`sales_end_at`, never a live inventory count
- A cookie-less, always-`anon` Supabase client (`src/lib/supabase/public.ts`)
  so the public route's database access never depends on the visitor's own
  login state (see ADR-012 in
  [docs/architecture.md](docs/architecture.md))
- Three new `to anon` RLS SELECT policies (events, ticket_types,
  organizations) plus a column-level privilege restriction on
  `organizations`, scoped to PUBLISHED events only — the existing
  organizer-facing (`to authenticated`) policies are untouched
- A uniform not-found response (`notFound()`) for every case a buyer
  should not be able to distinguish: nonexistent event, DRAFT/FINISHED/
  CANCELLED/ARCHIVED event, wrong organization/event slug combination
- Timezone-correct date/time rendering using the organization's own IANA
  timezone (`Intl.DateTimeFormat`), not the browser's or server's
- 18 new pgTAP assertions covering the new migration (74 total with
  RFC-002/RFC-003/RFC-004)
- [docs/rfcs/RFC-005-public-event-page.md](docs/rfcs/RFC-005-public-event-page.md)

## What RFC-005 intentionally does NOT include

No checkout, shopping cart, order creation, order items, ticket holds,
inventory reservations, Mercado Pago, payment intents/preferences, payment
webhooks, buyer accounts, ticket issuance, QR codes, email delivery,
check-in, guest lists, discount codes, ticket transfer/resale, refunds,
billing, settlements, promoters, merchandising, audience CRM, analytics,
custom domains, an image upload system, or seat maps. The "Select" button
next to each ticket type is intentionally non-functional — it is not
checkout. Those arrive in RFC-006 and later.
