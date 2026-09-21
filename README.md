# Lucky Ticket

Ticketera local para bandas y productores — a multi-tenant platform for
independent event organizers, producers, bands, and venues. Ticketing is the
first module of a longer-term "operating system for independent events"
(check-in, guest lists, audience database, billing, and more, added
incrementally).

**Current implementation stage: RFC-002 — Database Schema & Multi-Tenant
Security**

RFC-001 established the technical foundation (Next.js, Supabase client
plumbing). RFC-002 adds the full database schema, tenant isolation, and Row
Level Security as Supabase migrations — no application code queries it yet.
See [docs/architecture.md](docs/architecture.md) for the application
architecture and [docs/database.md](docs/database.md) for the database
design, security model, and decision log.

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
npx supabase test db    # runs the pgTAP security/integrity suite
npx supabase gen types typescript --local > src/types/database.ts
```

See [docs/database.md](docs/database.md) for the schema, tenant-isolation
strategy, RLS policies, and how this was verified in an environment without
Docker registry access.

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
