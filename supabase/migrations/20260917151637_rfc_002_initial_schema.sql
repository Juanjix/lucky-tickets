-- RFC-002: Database Schema & Multi-Tenant Security
--
-- This migration establishes the full domain schema for Lucky Ticket: every
-- table is created disabled to client traffic until its Row Level Security
-- policies are declared in the "RLS" section near the end of this file.
--
-- Conventions used throughout (see docs/database.md for the full rationale):
--   - Money: integer minor units in `bigint` columns, explicit names
--     (never `amount`/`total`/`price` alone), currency stored separately.
--   - Time: `timestamptz` everywhere, defaulting to `now()`.
--   - IDs: `uuid` primary keys via `gen_random_uuid()` (built into Postgres
--     core since v13 — no extension required).
--   - Tenant consistency: every table that hangs off another tenant-scoped
--     table (not directly off `organizations`) uses a composite foreign key
--     of the form `(organization_id, parent_id) references
--     parent_table(organization_id, id)` instead of a plain
--     `parent_id references parent_table(id)`. This makes it a schema-level
--     impossibility to attach a child row to a parent in a different
--     organization — see "Tenant consistency" in docs/database.md.
--   - Deletion: `on delete restrict` from every business table back to
--     `organizations` (an organization with any data cannot be hard
--     deleted — archive it via `status` instead). `on delete cascade` is
--     reserved for rows that are pure, disposable extensions of their
--     parent (e.g. `profiles`, `organization_members`). Financial/history
--     tables (orders, payments, tickets, check_ins, settlements,
--     audit_logs) never cascade away and have no client-facing DELETE
--     policy at all.
--
-- This migration creates schema only. No product/business flow (checkout,
-- payments, ticket issuance, check-in, webhooks) is implemented here.

-- =============================================================================
-- ENUMS
-- =============================================================================
-- PostgreSQL enums are used only for genuinely stable, closed sets of
-- lifecycle states — see docs/database.md "Enum strategy" for why each one
-- exists and why some concepts (e.g. "on sale", "sold out") are deliberately
-- NOT enums: those are derived at query time, not persisted state.

create type public.organization_status as enum (
  'ACTIVE',
  'SUSPENDED',
  'ARCHIVED'
);

create type public.organization_role as enum (
  'OWNER',
  'ADMIN',
  'PRODUCER',
  'DOOR_STAFF',
  'VIEWER'
);

create type public.event_status as enum (
  'DRAFT',
  'PUBLISHED',
  'FINISHED',
  'CANCELLED',
  'ARCHIVED'
);

create type public.order_status as enum (
  'DRAFT',
  'PENDING_PAYMENT',
  'PAID',
  'PAYMENT_FAILED',
  'EXPIRED',
  'CANCELLED',
  'REFUNDED',
  'PARTIALLY_REFUNDED'
);

create type public.payment_status as enum (
  'PENDING',
  'APPROVED',
  'REJECTED',
  'CANCELLED',
  'REFUNDED',
  'PARTIALLY_REFUNDED'
);

create type public.ticket_status as enum (
  'VALID',
  'CHECKED_IN',
  'CANCELLED',
  'REFUNDED'
);

create type public.guest_status as enum (
  'INVITED',
  'CHECKED_IN',
  'CANCELLED'
);

create type public.settlement_status as enum (
  'DRAFT',
  'PENDING',
  'PAID',
  'OVERDUE',
  'WAIVED'
);

create type public.fee_type as enum (
  'PERCENTAGE',
  'FIXED_PER_TICKET',
  'HYBRID',
  'CUSTOM'
);

-- Ticket-type visibility. Kept to the smallest useful model: a ticket type
-- is either shown on the (future) public sale page, or it isn't (comp/guest
-- allocations, presale-only types managed by staff). A richer model
-- (password-protected, scheduled reveal, ...) is deferred until a feature
-- actually needs it.
create type public.ticket_visibility as enum (
  'PUBLIC',
  'HIDDEN'
);

-- One value per external payment processor Lucky Ticket integrates with.
-- Kept as an enum (not free text) because "which providers exist" is a
-- deliberately curated list that drives provider-specific logic elsewhere —
-- see ADR-005 (provider abstraction) in docs/architecture.md. Adding a
-- provider later is a single additive `alter type ... add value`, which is
-- safe and does not require touching existing rows.
create type public.payment_provider as enum (
  'MERCADO_PAGO'
);

-- Lifecycle of a single inbound webhook delivery (infrastructure-level, not
-- a business state). RECEIVED: stored, not yet handled. PROCESSED: handled
-- successfully. FAILED: handling raised an error (retryable). IGNORED:
-- deliberately skipped (e.g. an event type we don't act on, or a replay of
-- an already-processed event).
create type public.webhook_status as enum (
  'RECEIVED',
  'PROCESSED',
  'FAILED',
  'IGNORED'
);

-- =============================================================================
-- SHARED HELPER: updated_at
-- =============================================================================
-- One reusable trigger function instead of duplicating the same three lines
-- per table.

create function public.set_updated_at()
returns trigger
language plpgsql
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

comment on function public.set_updated_at() is
  'Reusable BEFORE UPDATE trigger: stamps updated_at = now() on every row update. Attached per-table below.';

-- =============================================================================
-- PROFILES
-- =============================================================================
-- A minimal, Supabase-Auth-compatible profile row. Email and all credential
-- data stay owned by `auth.users` — this table never duplicates them.

create table public.profiles (
  id uuid primary key references auth.users (id) on delete cascade,
  display_name text,
  avatar_url text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

comment on table public.profiles is
  'Minimal public-facing extension of auth.users. Cascades on user deletion because it is a pure 1:1 display extension, not a historical/business record.';

create trigger set_updated_at
  before update on public.profiles
  for each row execute function public.set_updated_at();

-- Auto-provision a profile row whenever a new auth user is created.
-- Minimal, safe, idempotent (ON CONFLICT DO NOTHING — never errors if a
-- profile already exists), and schema-qualified with a locked-down
-- search_path since it runs SECURITY DEFINER on a system schema trigger.
create function public.handle_new_user()
returns trigger
language plpgsql
security definer
set search_path = public, pg_temp
as $$
begin
  insert into public.profiles (id)
  values (new.id)
  on conflict (id) do nothing;
  return new;
end;
$$;

comment on function public.handle_new_user() is
  'Idempotently creates a public.profiles row for every new auth.users row. SECURITY DEFINER is required to insert into public.profiles from a trigger on auth.users; search_path is locked to prevent hijacking.';

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- =============================================================================
-- ORGANIZATIONS (the tenant boundary)
-- =============================================================================

create table public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  slug text not null,
  logo_url text,
  status public.organization_status not null default 'ACTIVE',
  currency char(3) not null default 'ARS',
  timezone text not null default 'America/Argentina/Buenos_Aires',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint organizations_name_not_blank check (btrim(name) <> ''),
  -- Slug convention: lowercase ascii, digits, single hyphens between
  -- segments, no leading/trailing hyphen. Application code is responsible
  -- for normalizing a user-entered name into this form before insert; the
  -- database enforces that whatever lands here already conforms.
  constraint organizations_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  -- Structural length is enforced by char(3); this additionally requires
  -- uppercase letters (char(3) alone would accept 'us ' as blank-padded).
  -- Not validated against the full ISO 4217 list — deferred, see docs/database.md.
  constraint organizations_currency_format check (currency ~ '^[A-Z]{3}$')
);

comment on table public.organizations is
  'The tenant boundary. Every business table hangs off an organization, directly or transitively. Never ON DELETE CASCADE onto this table from a child - see docs/database.md "Deletion strategy".';

create unique index organizations_slug_key on public.organizations (slug);

create trigger set_updated_at
  before update on public.organizations
  for each row execute function public.set_updated_at();

-- =============================================================================
-- ORGANIZATION MEMBERS
-- =============================================================================

create table public.organization_members (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete cascade,
  user_id uuid not null references auth.users (id) on delete cascade,
  role public.organization_role not null default 'VIEWER',
  created_at timestamptz not null default now(),
  constraint organization_members_org_user_key unique (organization_id, user_id)
);

comment on table public.organization_members is
  'Join table between auth.users and organizations. CASCADEs on either side deliberately: membership is a current-state relationship, not historical/financial record - see docs/database.md "Deletion strategy".';

create index organization_members_user_id_idx on public.organization_members (user_id);
-- No separate index on (organization_id) alone: the UNIQUE(organization_id, user_id)
-- constraint above already backs organization_id-prefix queries ("list members of org X").

-- =============================================================================
-- EVENTS
-- =============================================================================

create table public.events (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  name text not null,
  slug text not null,
  description text,
  cover_image_url text,
  venue_name text,
  venue_address text,
  venue_city text,
  starts_at timestamptz not null,
  doors_open_at timestamptz,
  ends_at timestamptz,
  capacity integer,
  status public.event_status not null default 'DRAFT',
  sales_start_at timestamptz,
  sales_end_at timestamptz,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint events_name_not_blank check (btrim(name) <> ''),
  constraint events_slug_format check (slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'),
  constraint events_capacity_positive check (capacity is null or capacity > 0),
  constraint events_doors_before_starts check (doors_open_at is null or doors_open_at <= starts_at),
  constraint events_ends_after_starts check (ends_at is null or ends_at >= starts_at),
  constraint events_sales_window_order check (
    sales_start_at is null or sales_end_at is null or sales_start_at <= sales_end_at
  ),
  -- Scoped uniqueness, not global: two different organizations may each
  -- have their own event at slug "opening-night".
  constraint events_org_slug_key unique (organization_id, slug),
  -- Enables composite (organization_id, event_id) foreign keys from every
  -- child table below - the core tenant-consistency mechanism.
  constraint events_org_id_key unique (organization_id, id)
);

comment on table public.events is
  'Only persists lifecycle state (DRAFT/PUBLISHED/FINISHED/CANCELLED/ARCHIVED). Derived concepts like ON_SALE/SOLD_OUT are computed at query time from sales_start_at/sales_end_at/ticket inventory, never stored.';

create index events_org_status_idx on public.events (organization_id, status);
-- Covers plain "events for this org" lookups too (organization_id is the
-- leading column), so a separate events(organization_id) index would be
-- redundant.

create trigger set_updated_at
  before update on public.events
  for each row execute function public.set_updated_at();

-- =============================================================================
-- TICKET TYPES
-- =============================================================================

create table public.ticket_types (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  name text not null,
  description text,
  unit_price_amount bigint not null,
  currency char(3) not null,
  quantity integer not null,
  sales_start_at timestamptz,
  sales_end_at timestamptz,
  max_per_order integer not null default 10,
  visibility public.ticket_visibility not null default 'PUBLIC',
  sort_order integer not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint ticket_types_name_not_blank check (btrim(name) <> ''),
  constraint ticket_types_unit_price_non_negative check (unit_price_amount >= 0),
  constraint ticket_types_currency_format check (currency ~ '^[A-Z]{3}$'),
  constraint ticket_types_quantity_positive check (quantity > 0),
  constraint ticket_types_max_per_order_positive check (max_per_order > 0),
  constraint ticket_types_sales_window_order check (
    sales_start_at is null or sales_end_at is null or sales_start_at <= sales_end_at
  ),
  constraint ticket_types_org_id_key unique (organization_id, id),
  -- Tenant consistency: a ticket type's event must belong to the SAME
  -- organization as the ticket type itself. This is what makes it a schema
  -- error (not just an app bug) to attach a ticket type to another org's event.
  constraint ticket_types_org_event_fk foreign key (organization_id, event_id)
    references public.events (organization_id, id) on delete restrict
);

comment on table public.ticket_types is
  'Tenant consistency enforced via composite FK to events(organization_id, id) - see migration header and docs/database.md.';

create index ticket_types_org_event_idx on public.ticket_types (organization_id, event_id);
-- Backs the composite FK above and the dominant access pattern (ticket
-- types for a given org's event). The RFC's suggested plain ticket_types(event_id)
-- index is intentionally not created separately - see docs/database.md
-- "Indexing strategy" for why the composite is preferred here.

create trigger set_updated_at
  before update on public.ticket_types
  for each row execute function public.set_updated_at();

-- =============================================================================
-- CUSTOMERS / AUDIENCE
-- =============================================================================

create table public.customers (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  email text not null,
  -- Generated, not trigger-maintained: declarative, always in sync, and
  -- the only reliable way to express case-insensitive uniqueness below.
  normalized_email text generated always as (lower(btrim(email))) stored,
  name text,
  phone text,
  first_seen_at timestamptz not null default now(),
  last_seen_at timestamptz not null default now(),
  marketing_consent boolean not null default false,
  marketing_consent_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint customers_email_not_blank check (btrim(email) <> ''),
  constraint customers_consent_timestamp_consistency check (
    marketing_consent_at is null or marketing_consent
  ),
  constraint customers_org_id_key unique (organization_id, id),
  -- Case-insensitive uniqueness per organization. Two different
  -- organizations may each have a customer with the same email - audience
  -- data is per-tenant, never shared or deduplicated across organizations.
  constraint customers_org_normalized_email_key unique (organization_id, normalized_email)
);

comment on table public.customers is
  'Per-organization audience/CRM record. No cross-organization dedup by design - see docs/database.md. Aggregate columns (total_orders, total_spent, ...) are deliberately NOT stored here; derive them by query to avoid a synchronization problem RFC-002 has no flow to keep correct yet.';

create index customers_org_id_idx on public.customers (organization_id);

create trigger set_updated_at
  before update on public.customers
  for each row execute function public.set_updated_at();

-- =============================================================================
-- ORDERS
-- =============================================================================

create table public.orders (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  customer_id uuid,
  order_number text not null,
  -- Buyer snapshot at time of purchase. Deliberately NOT a join to
  -- customers/profiles: if the customer later changes their name or email,
  -- this historical purchase record must not silently change with them.
  buyer_name text not null,
  buyer_email text not null,
  buyer_phone text,
  currency char(3) not null,
  subtotal_amount bigint not null,
  service_fee_amount bigint not null default 0,
  total_amount bigint not null,
  status public.order_status not null default 'DRAFT',
  expires_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint orders_buyer_name_not_blank check (btrim(buyer_name) <> ''),
  constraint orders_buyer_email_not_blank check (btrim(buyer_email) <> ''),
  constraint orders_currency_format check (currency ~ '^[A-Z]{3}$'),
  constraint orders_subtotal_non_negative check (subtotal_amount >= 0),
  constraint orders_service_fee_non_negative check (service_fee_amount >= 0),
  constraint orders_total_non_negative check (total_amount >= 0),
  constraint orders_total_arithmetic check (total_amount = subtotal_amount + service_fee_amount),
  constraint orders_org_id_key unique (organization_id, id),
  constraint orders_org_number_key unique (organization_id, order_number),
  constraint orders_org_event_fk foreign key (organization_id, event_id)
    references public.events (organization_id, id) on delete restrict,
  constraint orders_org_customer_fk foreign key (organization_id, customer_id)
    references public.customers (organization_id, id) on delete restrict
);

comment on table public.orders is
  'Financial history - no client-facing DELETE policy is defined for this table (see RLS section). buyer_* columns are a point-in-time snapshot, independent of the customers row they may also reference.';

create index orders_org_event_status_idx on public.orders (organization_id, event_id, status);
create index orders_org_customer_idx on public.orders (organization_id, customer_id);
-- organization_id-only and (organization_id, status)-only queries are both
-- served by orders_org_event_status_idx's leading columns being usable as
-- prefixes; a dedicated (organization_id, status) index is added anyway
-- because "all pending orders for this org" (regardless of event) is a
-- realistic, separate access pattern that the event-first composite above
-- cannot serve efficiently.
create index orders_org_status_idx on public.orders (organization_id, status);

create trigger set_updated_at
  before update on public.orders
  for each row execute function public.set_updated_at();

-- =============================================================================
-- ORDER ITEMS
-- =============================================================================

create table public.order_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  order_id uuid not null,
  ticket_type_id uuid not null,
  -- Snapshot fields: a ticket type's name/price can change after purchase
  -- without rewriting what was actually bought.
  name_snapshot text not null,
  unit_price_amount bigint not null,
  quantity integer not null,
  subtotal_amount bigint not null,
  created_at timestamptz not null default now(),
  constraint order_items_name_snapshot_not_blank check (btrim(name_snapshot) <> ''),
  constraint order_items_quantity_positive check (quantity > 0),
  constraint order_items_unit_price_non_negative check (unit_price_amount >= 0),
  constraint order_items_subtotal_non_negative check (subtotal_amount >= 0),
  constraint order_items_subtotal_arithmetic check (subtotal_amount = unit_price_amount * quantity),
  constraint order_items_org_id_key unique (organization_id, id),
  constraint order_items_org_order_fk foreign key (organization_id, order_id)
    references public.orders (organization_id, id) on delete restrict,
  constraint order_items_org_ticket_type_fk foreign key (organization_id, ticket_type_id)
    references public.ticket_types (organization_id, id) on delete restrict
);

comment on table public.order_items is
  'name_snapshot/unit_price_amount are frozen at purchase time and never rewritten when the referenced ticket_type changes later.';

create index order_items_org_order_idx on public.order_items (organization_id, order_id);
create index order_items_org_ticket_type_idx on public.order_items (organization_id, ticket_type_id);

-- =============================================================================
-- TICKET HOLDS
-- =============================================================================
-- Storage + constraints only. Concurrency-safe reservation/release logic is
-- explicitly deferred to the commerce RFC (RFC-002 section 16).

create table public.ticket_holds (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  ticket_type_id uuid not null,
  order_id uuid,
  quantity integer not null,
  expires_at timestamptz not null,
  created_at timestamptz not null default now(),
  constraint ticket_holds_quantity_positive check (quantity > 0),
  constraint ticket_holds_org_event_fk foreign key (organization_id, event_id)
    references public.events (organization_id, id) on delete restrict,
  constraint ticket_holds_org_ticket_type_fk foreign key (organization_id, ticket_type_id)
    references public.ticket_types (organization_id, id) on delete restrict,
  -- order_id is nullable: a hold can exist before checkout produces an
  -- order. When present, it must belong to the same organization.
  constraint ticket_holds_org_order_fk foreign key (organization_id, order_id)
    references public.orders (organization_id, id) on delete restrict
);

comment on table public.ticket_holds is
  'Prevents overselling during checkout. Row storage + constraints only - no acquisition/release function is implemented (RFC-002 scope). "Expired" is a query predicate (expires_at < now()), never a stored derived state.';

create index ticket_holds_org_ticket_type_expires_idx
  on public.ticket_holds (organization_id, ticket_type_id, expires_at);
-- Serves the RFC's suggested (ticket_type_id, expires_at) access pattern
-- with organization_id prepended, since every realistic query is also
-- tenant-scoped and this also backs the composite FK to ticket_types.
create index ticket_holds_org_event_idx on public.ticket_holds (organization_id, event_id);
create index ticket_holds_org_order_idx on public.ticket_holds (organization_id, order_id);

-- =============================================================================
-- PAYMENTS
-- =============================================================================
-- Provider-neutral: no Mercado-Pago-specific columns. provider_payload
-- holds the raw provider response for audit/debugging.

create table public.payments (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  order_id uuid not null,
  provider public.payment_provider not null,
  provider_payment_id text not null,
  provider_order_id text,
  status public.payment_status not null default 'PENDING',
  -- Naming convention (see docs/database.md "Money representation"): this
  -- is the amount the provider actually processed for THIS payment record,
  -- in integer minor units - not necessarily equal to orders.total_amount
  -- (e.g. a partial refund is reflected in status, a future separate
  -- payment row, or a future refunds table, not by mutating this value).
  paid_amount bigint not null,
  currency char(3) not null,
  payment_method text,
  provider_payload jsonb not null default '{}'::jsonb,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payments_paid_amount_non_negative check (paid_amount >= 0),
  constraint payments_currency_format check (currency ~ '^[A-Z]{3}$'),
  constraint payments_provider_payment_id_not_blank check (btrim(provider_payment_id) <> ''),
  constraint payments_org_order_fk foreign key (organization_id, order_id)
    references public.orders (organization_id, id) on delete restrict,
  -- Idempotency: the same provider can never report the same payment id twice.
  constraint payments_provider_payment_key unique (provider, provider_payment_id)
);

comment on table public.payments is
  'Provider-neutral. Financial history - no client-facing DELETE policy. Mercado Pago is not implemented; provider is stored as data, not assumed in code.';

create index payments_org_order_idx on public.payments (organization_id, order_id);

create trigger set_updated_at
  before update on public.payments
  for each row execute function public.set_updated_at();

-- =============================================================================
-- TICKETS
-- =============================================================================
-- Issuance and QR generation are not implemented (RFC-002 section 18). Only
-- a hash of the QR token is ever stored - the raw token never touches the
-- database, by construction (there is no column for it).

create table public.tickets (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  order_id uuid not null,
  order_item_id uuid not null,
  ticket_type_id uuid not null,
  ticket_number text not null,
  -- Nullable: issuance (which assigns a holder) is not implemented yet:
  -- see docs/database.md for why these aren't NOT NULL in RFC-002.
  holder_name text,
  holder_email text,
  -- Strong hash output (e.g. SHA-256, hex or base64 encoded) of a future
  -- cryptographically random QR token. Never the raw token itself.
  qr_token_hash text,
  status public.ticket_status not null default 'VALID',
  issued_at timestamptz,
  checked_in_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint tickets_org_id_key unique (organization_id, id),
  constraint tickets_org_number_key unique (organization_id, ticket_number),
  -- A hash, once assigned, must be unique across the whole platform (a
  -- plain UNIQUE constraint already allows unlimited NULLs, which is what
  -- every not-yet-issued ticket will have).
  constraint tickets_qr_token_hash_key unique (qr_token_hash),
  constraint tickets_org_event_fk foreign key (organization_id, event_id)
    references public.events (organization_id, id) on delete restrict,
  constraint tickets_org_order_fk foreign key (organization_id, order_id)
    references public.orders (organization_id, id) on delete restrict,
  constraint tickets_org_order_item_fk foreign key (organization_id, order_item_id)
    references public.order_items (organization_id, id) on delete restrict,
  constraint tickets_org_ticket_type_fk foreign key (organization_id, ticket_type_id)
    references public.ticket_types (organization_id, id) on delete restrict
);

comment on table public.tickets is
  'ticket_number is a display/reference identifier only - it grants no authorization. qr_token_hash stores a hash only; raw QR secrets are never persisted. Issuance (populating holder_*, qr_token_hash, issued_at) is deferred to a later RFC.';

create index tickets_org_event_idx on public.tickets (organization_id, event_id);
create index tickets_org_order_idx on public.tickets (organization_id, order_id);
create index tickets_org_order_item_idx on public.tickets (organization_id, order_item_id);
create index tickets_org_ticket_type_idx on public.tickets (organization_id, ticket_type_id);
-- tickets_qr_token_hash_key (above) already provides an index on
-- qr_token_hash for fast lookup at scan time - no separate index needed.

create trigger set_updated_at
  before update on public.tickets
  for each row execute function public.set_updated_at();

-- =============================================================================
-- CHECK-INS
-- =============================================================================
-- Append-only by convention (no UPDATE/DELETE policy is granted to any
-- client role - see RLS section). The atomic "scan and check in" function
-- (which would also transition tickets.status) is explicitly deferred to
-- the Door RFC; UNIQUE(ticket_id) below is the one schema-level primitive
-- RFC-002 adds to prevent a ticket from ever having two check-in records.

create table public.check_ins (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  ticket_id uuid not null,
  checked_in_by uuid references auth.users (id) on delete set null,
  gate text,
  device_id text,
  created_at timestamptz not null default now(),
  constraint check_ins_ticket_key unique (ticket_id),
  constraint check_ins_org_event_fk foreign key (organization_id, event_id)
    references public.events (organization_id, id) on delete restrict,
  constraint check_ins_org_ticket_fk foreign key (organization_id, ticket_id)
    references public.tickets (organization_id, id) on delete restrict
);

comment on table public.check_ins is
  'Append-only history: no UPDATE/DELETE policy exists for any client role. checked_in_by is SET NULL (not restricted/cascaded) on user deletion so the historical record survives even if the staff account is later removed. UNIQUE(ticket_id) guarantees at most one check-in per ticket at the database level.';

create index check_ins_org_event_idx on public.check_ins (organization_id, event_id);
-- check_ins_ticket_key (above) already indexes ticket_id.

-- =============================================================================
-- GUEST LISTS & GUESTS
-- =============================================================================

create table public.guest_lists (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  name text not null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint guest_lists_name_not_blank check (btrim(name) <> ''),
  constraint guest_lists_org_id_key unique (organization_id, id),
  constraint guest_lists_org_event_fk foreign key (organization_id, event_id)
    references public.events (organization_id, id) on delete restrict
);

create index guest_lists_org_event_idx on public.guest_lists (organization_id, event_id);

create trigger set_updated_at
  before update on public.guest_lists
  for each row execute function public.set_updated_at();

create table public.guests (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  guest_list_id uuid not null,
  name text not null,
  email text,
  phone text,
  quantity integer not null default 1,
  notes text,
  status public.guest_status not null default 'INVITED',
  checked_in_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint guests_name_not_blank check (btrim(name) <> ''),
  constraint guests_quantity_positive check (quantity > 0),
  constraint guests_org_event_fk foreign key (organization_id, event_id)
    references public.events (organization_id, id) on delete restrict,
  constraint guests_org_guest_list_fk foreign key (organization_id, guest_list_id)
    references public.guest_lists (organization_id, id) on delete restrict
);

comment on table public.guests is
  'Guests are a distinct concept from tickets in the MVP (comp/invite list, not a paid inventory item). Check-in of a guest is a separate future flow from ticket check-in.';

create index guests_org_event_idx on public.guests (organization_id, event_id);
create index guests_org_guest_list_idx on public.guests (organization_id, guest_list_id);

create trigger set_updated_at
  before update on public.guests
  for each row execute function public.set_updated_at();

-- =============================================================================
-- PAYMENT ACCOUNTS
-- =============================================================================
-- Connection metadata only. No OAuth token, secret, or credential column
-- exists here or anywhere else in this migration - see RFC-002 section 21
-- and docs/database.md. A future payment RFC introduces a secure,
-- server-only storage strategy for credentials; this table is not it.

create table public.payment_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  provider public.payment_provider not null,
  provider_account_id text not null,
  status public.organization_status not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint payment_accounts_provider_account_id_not_blank check (btrim(provider_account_id) <> ''),
  constraint payment_accounts_org_provider_key unique (organization_id, provider)
);

comment on table public.payment_accounts is
  'Connection metadata (which provider, which external account id) only - never a credential/token store. status reuses organization_status (ACTIVE/SUSPENDED/ARCHIVED) since a payment account has the same coarse lifecycle; introduce a dedicated enum if its states ever diverge.';

-- No separate organization_id index: the UNIQUE(organization_id, provider)
-- constraint above already backs organization_id-prefix queries.

create trigger set_updated_at
  before update on public.payment_accounts
  for each row execute function public.set_updated_at();

-- =============================================================================
-- BILLING ACCOUNTS
-- =============================================================================
-- Fee *configuration* only - no fee calculation logic is implemented here.

create table public.billing_accounts (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null references public.organizations (id) on delete restrict,
  fee_type public.fee_type not null,
  -- Basis points, never floating point: 500 = 5.00%.
  fee_percentage_bps integer,
  fee_fixed_amount bigint,
  status public.organization_status not null default 'ACTIVE',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint billing_accounts_org_key unique (organization_id),
  constraint billing_accounts_fee_percentage_bps_range check (
    fee_percentage_bps is null or fee_percentage_bps between 0 and 10000
  ),
  constraint billing_accounts_fee_fixed_amount_non_negative check (
    fee_fixed_amount is null or fee_fixed_amount >= 0
  ),
  -- Each fee_type requires the field(s) it actually uses to be present,
  -- and forbids the other. CUSTOM opts out of both (fee computed by logic
  -- not yet built) - deliberately permissive since RFC-002 does not
  -- implement fee calculation.
  constraint billing_accounts_fee_fields_match_type check (
    case fee_type
      when 'PERCENTAGE' then fee_percentage_bps is not null and fee_fixed_amount is null
      when 'FIXED_PER_TICKET' then fee_fixed_amount is not null and fee_percentage_bps is null
      when 'HYBRID' then fee_percentage_bps is not null and fee_fixed_amount is not null
      when 'CUSTOM' then true
    end
  )
);

comment on table public.billing_accounts is
  'Fee configuration only ("creating an event costs nothing; the platform earns when tickets are sold" - no fee calculation is implemented in RFC-002). One row per organization.';

create trigger set_updated_at
  before update on public.billing_accounts
  for each row execute function public.set_updated_at();

-- =============================================================================
-- SETTLEMENTS
-- =============================================================================
-- Storage only - no automatic settlement generation is implemented.

create table public.settlements (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  event_id uuid not null,
  gross_sales_amount bigint not null default 0,
  tickets_sold integer not null default 0,
  platform_fee_amount bigint not null default 0,
  currency char(3) not null,
  status public.settlement_status not null default 'DRAFT',
  generated_at timestamptz,
  due_at timestamptz,
  paid_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint settlements_gross_sales_non_negative check (gross_sales_amount >= 0),
  constraint settlements_tickets_sold_non_negative check (tickets_sold >= 0),
  constraint settlements_platform_fee_non_negative check (platform_fee_amount >= 0),
  constraint settlements_currency_format check (currency ~ '^[A-Z]{3}$'),
  constraint settlements_org_id_key unique (organization_id, id),
  constraint settlements_org_event_fk foreign key (organization_id, event_id)
    references public.events (organization_id, id) on delete restrict
);

comment on table public.settlements is
  'Financial history - no client-facing DELETE policy. No automatic generation logic exists yet; rows are expected to be produced by a future service-role process.';

create index settlements_org_event_idx on public.settlements (organization_id, event_id);
-- Covers the RFC's suggested plain settlements(organization_id) pattern
-- too, via prefix, while also backing the composite FK to events.

create trigger set_updated_at
  before update on public.settlements
  for each row execute function public.set_updated_at();

create table public.settlement_items (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid not null,
  settlement_id uuid not null,
  ticket_type_id uuid,
  description text not null,
  quantity integer,
  gross_amount bigint not null default 0,
  fee_amount bigint not null default 0,
  net_amount bigint not null default 0,
  created_at timestamptz not null default now(),
  constraint settlement_items_description_not_blank check (btrim(description) <> ''),
  constraint settlement_items_quantity_positive check (quantity is null or quantity > 0),
  constraint settlement_items_gross_non_negative check (gross_amount >= 0),
  constraint settlement_items_fee_non_negative check (fee_amount >= 0),
  constraint settlement_items_net_arithmetic check (net_amount = gross_amount - fee_amount),
  constraint settlement_items_org_settlement_fk foreign key (organization_id, settlement_id)
    references public.settlements (organization_id, id) on delete restrict,
  constraint settlement_items_org_ticket_type_fk foreign key (organization_id, ticket_type_id)
    references public.ticket_types (organization_id, id) on delete restrict
);

comment on table public.settlement_items is
  'Auditable per-line breakdown of a settlement. Exact shape (one row per ticket type is assumed here) is a reasonable default for RFC-002 and may be revisited once real settlement generation is built.';

create index settlement_items_org_settlement_idx on public.settlement_items (organization_id, settlement_id);
create index settlement_items_org_ticket_type_idx on public.settlement_items (organization_id, ticket_type_id);

-- =============================================================================
-- WEBHOOK EVENTS (infrastructure-level, no tenant column)
-- =============================================================================
-- No HTTP route exists yet that writes to this table. Schema only.

create table public.webhook_events (
  id uuid primary key default gen_random_uuid(),
  provider public.payment_provider not null,
  provider_event_id text not null,
  event_type text not null,
  payload jsonb not null,
  status public.webhook_status not null default 'RECEIVED',
  received_at timestamptz not null default now(),
  processed_at timestamptz,
  error_message text,
  constraint webhook_events_provider_event_id_not_blank check (btrim(provider_event_id) <> ''),
  constraint webhook_events_event_type_not_blank check (btrim(event_type) <> ''),
  -- The idempotency guarantee: the same provider can never be recorded
  -- twice for the same event id, so a retried/duplicated webhook delivery
  -- is a no-op rather than double-processed.
  constraint webhook_events_provider_event_key unique (provider, provider_event_id)
);

comment on table public.webhook_events is
  'No organization_id: a webhook may arrive before its order/organization can be resolved. Not exposed to any client role (see RLS) - service-role only.';

-- =============================================================================
-- AUDIT LOGS
-- =============================================================================

create table public.audit_logs (
  id uuid primary key default gen_random_uuid(),
  organization_id uuid references public.organizations (id) on delete set null,
  actor_user_id uuid references auth.users (id) on delete set null,
  action text not null,
  entity_type text not null,
  entity_id uuid,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint audit_logs_action_not_blank check (btrim(action) <> ''),
  constraint audit_logs_entity_type_not_blank check (btrim(entity_type) <> '')
);

comment on table public.audit_logs is
  'Conceptually append-only: no UPDATE/DELETE policy exists for any client role, including OWNER/ADMIN (see RLS). organization_id/actor_user_id are SET NULL (never cascaded/restricted) so a record always survives its subject being deleted.';

create index audit_logs_org_created_idx on public.audit_logs (organization_id, created_at desc);
create index audit_logs_actor_idx on public.audit_logs (actor_user_id);

-- =============================================================================
-- RLS HELPER FUNCTIONS
-- =============================================================================
-- SECURITY DEFINER is required here: a policy on organization_members that
-- queried organization_members directly (even indirectly through a plain
-- SECURITY INVOKER function) would re-trigger its own RLS policy and
-- recurse (RFC-002 section 32). Running as SECURITY DEFINER means the
-- function's internal query bypasses RLS on organization_members entirely,
-- breaking the cycle. search_path is pinned and every reference is
-- schema-qualified to prevent search_path hijacking.

create function public.is_organization_member(target_organization_id uuid)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.organization_members m
    where m.organization_id = target_organization_id
      and m.user_id = auth.uid()
  );
$$;

comment on function public.is_organization_member(uuid) is
  'True if the current auth.uid() is a member of target_organization_id, regardless of role. SECURITY DEFINER to avoid RLS recursion on organization_members - see RFC-002 section 32.';

create function public.has_organization_role(
  target_organization_id uuid,
  allowed_roles public.organization_role[]
)
returns boolean
language sql
stable
security definer
set search_path = public, pg_temp
as $$
  select exists (
    select 1
    from public.organization_members m
    where m.organization_id = target_organization_id
      and m.user_id = auth.uid()
      and m.role = any(allowed_roles)
  );
$$;

comment on function public.has_organization_role(uuid, public.organization_role[]) is
  'True if the current auth.uid() belongs to target_organization_id with one of allowed_roles. SECURITY DEFINER for the same reason as is_organization_member().';

-- Both helpers must be callable by anon (an unauthenticated request has
-- auth.uid() = null, so every policy check below correctly evaluates to
-- false rather than erroring for lack of EXECUTE privilege).
grant execute on function public.is_organization_member(uuid) to anon, authenticated;
grant execute on function public.has_organization_role(uuid, public.organization_role[]) to anon, authenticated;

-- =============================================================================
-- RLS
-- =============================================================================
-- Default posture: RLS enabled everywhere, no anonymous access anywhere,
-- and NO client-facing INSERT/UPDATE/DELETE policy at all on transactional
-- business tables (orders, order_items, payments, tickets, ticket_holds,
-- settlements, settlement_items) — those rows are meant to be produced by
-- server-side/service-role commerce logic that does not exist until a
-- later RFC (see RFC-002 section 40 "Do NOT implement ... checkout").
-- Until then those tables are read-only even for OWNER/ADMIN via the API.
--
-- Role capability summary (full table in docs/database.md):
--   OWNER/ADMIN  - manage org, members, events, ticket types, customers,
--                  guests; read all financial/operational data.
--   PRODUCER     - manage events/ticket types/guests; read (not write)
--                  orders/tickets/check-ins for operational visibility;
--                  NO access to customers, payments, billing, settlements.
--   DOOR_STAFF   - read events/ticket types/tickets/guest lists/guests for
--                  their org; INSERT check_ins only. NO access to orders,
--                  payments, customers, billing, settlements.
--   VIEWER       - read-only across the same scope as PRODUCER.
-- OWNER vs ADMIN differ in exactly one place: billing_accounts and
-- payment_accounts are OWNER-write / ADMIN-read-only ("billing
-- administration" is modeled as an OWNER-level capability).

-- ---------------------------------------------------------------------------
-- profiles
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;

create policy profiles_select_own
  on public.profiles for select
  to authenticated
  using (id = auth.uid());

create policy profiles_update_own
  on public.profiles for update
  to authenticated
  using (id = auth.uid())
  with check (id = auth.uid());

-- No INSERT policy: rows are created exclusively by the handle_new_user()
-- trigger (SECURITY DEFINER, bypasses RLS). No DELETE policy: a profile's
-- lifecycle is tied to its auth.users row (ON DELETE CASCADE above).

-- ---------------------------------------------------------------------------
-- organizations
-- ---------------------------------------------------------------------------
alter table public.organizations enable row level security;

create policy organizations_select_member
  on public.organizations for select
  to authenticated
  using (public.is_organization_member(id));

-- Deliberately open to any authenticated user: creating a brand-new,
-- currently-empty organization is not a tenant-isolation risk (there is no
-- existing data to protect yet), and it is what makes the
-- organization_members bootstrap policy below reachable at all.
create policy organizations_insert_authenticated
  on public.organizations for insert
  to authenticated
  with check (true);

create policy organizations_update_admin
  on public.organizations for update
  to authenticated
  using (public.has_organization_role(id, array['OWNER', 'ADMIN']::public.organization_role[]))
  with check (public.has_organization_role(id, array['OWNER', 'ADMIN']::public.organization_role[]));

-- No DELETE policy: organizations are archived (status = 'ARCHIVED'), never
-- deleted through the API. (ON DELETE RESTRICT from every child table also
-- makes a populated organization physically undeletable regardless.)

-- ---------------------------------------------------------------------------
-- organization_members (the recursion-sensitive case - RFC-002 section 32)
-- ---------------------------------------------------------------------------
alter table public.organization_members enable row level security;

create policy organization_members_select_member
  on public.organization_members for select
  to authenticated
  using (public.is_organization_member(organization_id));

-- Two permissive INSERT policies (Postgres OR's them together):
--  1) Bootstrap: an authenticated user may make THEMSELVES the OWNER of an
--     organization that currently has zero members at all. This is what
--     lets a freshly created organization ever get an owner, since no one
--     can hold OWNER/ADMIN in it yet for policy (2) to apply.
--  2) Normal path: an existing OWNER/ADMIN may add any member.
create policy organization_members_insert_bootstrap_owner
  on public.organization_members for insert
  to authenticated
  with check (
    user_id = auth.uid()
    and role = 'OWNER'
    and not exists (
      select 1
      from public.organization_members existing
      where existing.organization_id = organization_members.organization_id
    )
  );

create policy organization_members_insert_by_admin
  on public.organization_members for insert
  to authenticated
  with check (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[])
  );

create policy organization_members_update_admin
  on public.organization_members for update
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]))
  with check (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

-- DELETE: an OWNER/ADMIN may remove any member, and any member may remove
-- themselves (leave the organization). Note: RFC-002 does not enforce "an
-- organization must always retain at least one OWNER" - see docs/database.md
-- "Deferred database behavior".
create policy organization_members_delete
  on public.organization_members for delete
  to authenticated
  using (
    user_id = auth.uid()
    or public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[])
  );

-- ---------------------------------------------------------------------------
-- events
-- ---------------------------------------------------------------------------
alter table public.events enable row level security;

create policy events_select_member
  on public.events for select
  to authenticated
  using (public.is_organization_member(organization_id));

create policy events_insert_operator
  on public.events for insert
  to authenticated
  with check (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  );

create policy events_update_operator
  on public.events for update
  to authenticated
  using (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  )
  with check (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  );

-- No DELETE policy: events are archived via status, not deleted (and are
-- rarely empty of dependent ticket_types/orders in practice anyway).

-- ---------------------------------------------------------------------------
-- ticket_types
-- ---------------------------------------------------------------------------
alter table public.ticket_types enable row level security;

create policy ticket_types_select_member
  on public.ticket_types for select
  to authenticated
  using (public.is_organization_member(organization_id));

create policy ticket_types_insert_operator
  on public.ticket_types for insert
  to authenticated
  with check (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  );

create policy ticket_types_update_operator
  on public.ticket_types for update
  to authenticated
  using (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  )
  with check (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  );

create policy ticket_types_delete_operator
  on public.ticket_types for delete
  to authenticated
  using (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  );

-- ---------------------------------------------------------------------------
-- customers (audience - protected from PRODUCER/DOOR_STAFF/VIEWER)
-- ---------------------------------------------------------------------------
alter table public.customers enable row level security;

create policy customers_select_admin
  on public.customers for select
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

create policy customers_insert_admin
  on public.customers for insert
  to authenticated
  with check (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

create policy customers_update_admin
  on public.customers for update
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]))
  with check (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

-- No DELETE policy in RFC-002 (data-retention/erasure policy deferred).

-- ---------------------------------------------------------------------------
-- orders / order_items / payments / tickets / ticket_holds
-- Read-only for authorized roles. No client-facing mutation: these rows are
-- produced by commerce/service-role logic that RFC-002 does not implement.
-- ---------------------------------------------------------------------------
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.payments enable row level security;
alter table public.tickets enable row level security;
alter table public.ticket_holds enable row level security;

create policy orders_select_operator
  on public.orders for select
  to authenticated
  using (
    public.has_organization_role(
      organization_id, array['OWNER', 'ADMIN', 'PRODUCER', 'VIEWER']::public.organization_role[]
    )
  );

create policy order_items_select_operator
  on public.order_items for select
  to authenticated
  using (
    public.has_organization_role(
      organization_id, array['OWNER', 'ADMIN', 'PRODUCER', 'VIEWER']::public.organization_role[]
    )
  );

-- Payments are financial detail, not general operational visibility:
-- DOOR_STAFF and PRODUCER/VIEWER do not see them, only OWNER/ADMIN do
-- (matches RFC-002 tests 5/6 for DOOR_STAFF and the "PRODUCER ... without
-- billing administration" framing).
create policy payments_select_admin
  on public.payments for select
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

-- Tickets are operationally visible more broadly, including to DOOR_STAFF
-- (who must be able to look up a ticket to check it in).
create policy tickets_select_operator
  on public.tickets for select
  to authenticated
  using (
    public.has_organization_role(
      organization_id,
      array['OWNER', 'ADMIN', 'PRODUCER', 'DOOR_STAFF', 'VIEWER']::public.organization_role[]
    )
  );

create policy ticket_holds_select_operator
  on public.ticket_holds for select
  to authenticated
  using (
    public.has_organization_role(
      organization_id, array['OWNER', 'ADMIN', 'PRODUCER', 'VIEWER']::public.organization_role[]
    )
  );

-- ---------------------------------------------------------------------------
-- check_ins (append-only: SELECT + INSERT only, no UPDATE/DELETE policy)
-- ---------------------------------------------------------------------------
alter table public.check_ins enable row level security;

create policy check_ins_select_operator
  on public.check_ins for select
  to authenticated
  using (
    public.has_organization_role(
      organization_id,
      array['OWNER', 'ADMIN', 'PRODUCER', 'DOOR_STAFF', 'VIEWER']::public.organization_role[]
    )
  );

create policy check_ins_insert_operator
  on public.check_ins for insert
  to authenticated
  with check (
    public.has_organization_role(
      organization_id, array['OWNER', 'ADMIN', 'PRODUCER', 'DOOR_STAFF']::public.organization_role[]
    )
  );

-- ---------------------------------------------------------------------------
-- guest_lists / guests
-- ---------------------------------------------------------------------------
alter table public.guest_lists enable row level security;
alter table public.guests enable row level security;

create policy guest_lists_select_operator
  on public.guest_lists for select
  to authenticated
  using (
    public.has_organization_role(
      organization_id,
      array['OWNER', 'ADMIN', 'PRODUCER', 'DOOR_STAFF', 'VIEWER']::public.organization_role[]
    )
  );

create policy guest_lists_write_operator
  on public.guest_lists for all
  to authenticated
  using (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  )
  with check (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  );

create policy guests_select_operator
  on public.guests for select
  to authenticated
  using (
    public.has_organization_role(
      organization_id,
      array['OWNER', 'ADMIN', 'PRODUCER', 'DOOR_STAFF', 'VIEWER']::public.organization_role[]
    )
  );

create policy guests_write_operator
  on public.guests for all
  to authenticated
  using (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  )
  with check (
    public.has_organization_role(organization_id, array['OWNER', 'ADMIN', 'PRODUCER']::public.organization_role[])
  );

-- Note: DOOR_STAFF has read-only guest access in RFC-002. Guest check-in
-- (which would need UPDATE) is deferred alongside the atomic ticket
-- check-in function - see RFC-002 sections 19/20 and docs/database.md.

-- ---------------------------------------------------------------------------
-- payment_accounts / billing_accounts
-- OWNER can read+write, ADMIN can read only - see the "role capability
-- summary" comment above for why this table draws that line.
-- ---------------------------------------------------------------------------
alter table public.payment_accounts enable row level security;
alter table public.billing_accounts enable row level security;

create policy payment_accounts_select_admin
  on public.payment_accounts for select
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

create policy payment_accounts_write_owner
  on public.payment_accounts for all
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER']::public.organization_role[]))
  with check (public.has_organization_role(organization_id, array['OWNER']::public.organization_role[]));

create policy billing_accounts_select_admin
  on public.billing_accounts for select
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

create policy billing_accounts_write_owner
  on public.billing_accounts for all
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER']::public.organization_role[]))
  with check (public.has_organization_role(organization_id, array['OWNER']::public.organization_role[]));

-- ---------------------------------------------------------------------------
-- settlements / settlement_items - financial, OWNER/ADMIN read-only.
-- No client-facing mutation (generation is a future automated process).
-- ---------------------------------------------------------------------------
alter table public.settlements enable row level security;
alter table public.settlement_items enable row level security;

create policy settlements_select_admin
  on public.settlements for select
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

create policy settlement_items_select_admin
  on public.settlement_items for select
  to authenticated
  using (public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[]));

-- ---------------------------------------------------------------------------
-- webhook_events / audit_logs
-- ---------------------------------------------------------------------------
alter table public.webhook_events enable row level security;
alter table public.audit_logs enable row level security;

-- webhook_events: intentionally zero policies for anon/authenticated.
-- There is no organization_id to scope by, and payloads may contain
-- provider data not meant for any tenant's eyes - service_role (which
-- bypasses RLS entirely) is the only reader/writer, once a later RFC adds
-- webhook routes.

-- audit_logs: readable by OWNER/ADMIN for their own organization; no
-- INSERT/UPDATE/DELETE policy for any client role at all (append-only;
-- writes come from service-role/privileged server code in later RFCs).
create policy audit_logs_select_admin
  on public.audit_logs for select
  to authenticated
  using (
    organization_id is not null
    and public.has_organization_role(organization_id, array['OWNER', 'ADMIN']::public.organization_role[])
  );
