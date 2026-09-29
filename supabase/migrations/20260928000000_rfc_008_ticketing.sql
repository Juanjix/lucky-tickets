-- RFC-008: Ticket Issuance & Secure QR
--
-- This migration is FORWARD-ONLY: every migration file for RFC-002 through
-- RFC-007 remains byte-for-byte untouched. Where a previously-defined
-- function's signature or return shape needs to change (here:
-- `confirm_order_payment`), this file DROPs and re-CREATEs it - the same
-- "live redefinition of the FUNCTION, not an edit to the historical
-- migration FILE" convention RFC-007 already established for
-- `get_checkout_order` (see 20260925000000_rfc_007_mercado_pago.sql).
--
-- ============================================================================
-- SCOPE
-- ============================================================================
-- When (and only when) `confirm_order_payment` (RFC-007) authoritatively
-- transitions an order to PAID, issue exactly one `tickets` row per
-- purchased unit (`sum(order_items.quantity)`), each with its own
-- independently-scannable secure QR credential. Every other concern -
-- scanning, check-in, door staff, offline mode, transfer, resale, wallet
-- passes, refund automation, email delivery, PDF tickets - is explicitly
-- OUT of scope (see docs/rfcs/RFC-008-ticketing.md "Non-goals").
--
-- ============================================================================
-- WHY ISSUANCE LIVES INSIDE `confirm_order_payment`'S OWN TRANSACTION
-- ============================================================================
-- Three architectures were considered (see docs/rfcs/RFC-008-ticketing.md
-- "Payment -> issuance integration" for the full writeup):
--   (A) Embed issuance in the SAME Postgres transaction as the PAID
--       transition.
--   (B) A Postgres trigger (AFTER UPDATE ... WHEN status changed to PAID).
--   (C) An outbox/job table processed by a separate worker.
-- (A) was chosen. `confirm_order_payment` (as re-verified against the live
-- source in this session) has exactly ONE place that transitions an order
-- to PAID - a single `update orders set status = 'PAID'` near the end of
-- the function, reached through one code path regardless of whether this
-- is a normal-window or late-recovery confirmation. Embedding a single
-- function call there costs nothing architecturally and buys the
-- strongest possible consistency: it is IMPOSSIBLE, even under a process
-- crash, network partition, or serverless cold-kill between two
-- statements, for an order to end up PAID with zero tickets, because
-- there is no gap between the two - they commit or roll back together.
-- (B) and (C) were rejected as unnecessary infrastructure for something
-- one transaction already solves elegantly (explicit user instruction:
-- "prioriza esa opcion" when a single Postgres transaction suffices).
--
-- A bug INSIDE issuance must never be able to roll back a genuine PAID
-- confirmation (payment truth must never regress because of a ticketing
-- bug) - `issue_tickets_for_order_safe` below exists solely to provide
-- that isolation: it calls the real issuance function inside its own
-- BEGIN/EXCEPTION block (an implicit plpgsql savepoint) and NEVER
-- re-raises, only records the failure to `audit_logs` for operator
-- diagnosis. `confirm_order_payment` itself stays completely oblivious to
-- whether issuance succeeded.
--
-- ============================================================================
-- IDEMPOTENCY & CONCURRENCY
-- ============================================================================
-- Mercado Pago (and any provider) may redeliver a webhook notification
-- multiple times. `confirm_order_payment` already absorbs a redelivered
-- notification as a pure no-op (ALREADY_PROCESSED / ORDER_ALREADY_PAID)
-- BEFORE it would ever call issuance again for that same PAID transition -
-- but issuance is ALSO made independently idempotent at the database
-- level, not via an application-level "if (tickets.length === 0)" check
-- (explicitly flagged as concurrency-unsafe), so that even a direct,
-- repeated, or concurrent call to `issue_tickets_for_order` for the same
-- order can never produce more than one ticket per purchased unit:
--
--   - New column `tickets.ticket_sequence` (1..quantity within an
--     order_item) plus a new
--     `unique (organization_id, order_item_id, ticket_sequence)`
--     constraint gives every "slot" a single deterministic identity.
--   - Issuance is one `insert ... select ... on conflict
--     (organization_id, order_item_id, ticket_sequence) do nothing`
--     statement. Two concurrent callers race the SAME unique index; the
--     database itself - not application logic - guarantees only one row
--     per slot ever survives, regardless of timing.
--   - `order_items` rows are immutable after order creation (no UPDATE
--     policy exists on that table - RFC-002/006), so "how many tickets
--     should this order ever have" never changes after the fact: issuance
--     is always all-or-nothing per call, and repeat calls are pure no-ops
--     once every slot is filled.
--
-- ============================================================================
-- QR SECRET DESIGN (the redisplay problem)
-- ============================================================================
-- Forbidden sources (ticket.id, order.id, sequential ids, email, a hash of
-- any of those, a reused/predictable UUID) are never used. Each ticket's
-- QR secret is a fresh 32-byte value from Postgres's own CSPRNG
-- (`pgcrypto`'s `gen_random_bytes`, backed by OpenSSL's `RAND_bytes` - the
-- same class of primitive `crypto.randomBytes` uses in Node, chosen here
-- specifically so generation can happen inside the SAME atomic,
-- concurrency-safe INSERT as everything else in this migration - see
-- docs/rfcs/RFC-008-ticketing.md "Why Postgres-side CSPRNG" for the full
-- tradeoff discussion against generating it in Node instead), hex-encoded
-- to match the exact convention `src/lib/checkout/token.ts` already
-- established for checkout tokens.
--
-- The raw token is NEVER stored as-is. Two derived values are stored:
--   1. `qr_token_hash` (existing RFC-002 column) = sha256(raw token),
--      exactly the checkout-token convention - fast, one-way, sufficient
--      for RFC-009's scan-time validation (a plain equality lookup, no
--      decryption on the hot check-in path).
--   2. `qr_secret_ciphertext` (new column) = `pgp_sym_encrypt(raw token,
--      key, 'cipher-algo=aes256')` - lets the SAME server that issued the
--      ticket later decrypt and re-render the QR for the buyer, without
--      ever having persisted the raw value anywhere. The encryption key
--      is a new server-only secret (`QR_ENCRYPTION_KEY`, validated by
--      `getTicketServerEnv()` in application code) that is passed into
--      this migration's functions as a plain call ARGUMENT and is never
--      written to any table, column, Postgres setting, or log by this
--      migration. A leak of the database alone therefore yields only
--      ciphertext plus a one-way hash - never a usable QR code.
--
-- pgp_sym_encrypt (OpenPGP symmetric encryption, not an authenticated
-- AEAD cipher like AES-GCM) was deliberately chosen over hand-rolling
-- AES-256-GCM in Node: it is a mature, audited primitive already bundled
-- with the `pgcrypto` extension this project already relies on for
-- `gen_random_uuid()`, it keeps the encryption step inside the same
-- Postgres transaction as issuance (see above), and the threat model here
-- never decrypts attacker-supplied ciphertext (only ciphertext this
-- server itself wrote, looked up by an already-authorized ticket row) -
-- exactly the case where AEAD's tamper-detection buys little over a
-- mature non-AEAD symmetric cipher. This tradeoff is documented as
-- ADR-0XX in docs/architecture.md; a future RFC can move to per-value
-- AEAD/KMS-backed encryption without changing the schema shape
-- (`qr_secret_version` is included from day one for exactly that future
-- migration path).
--
-- ============================================================================
-- BUYER ACCESS CAPABILITY (never reuse the checkout token)
-- ============================================================================
-- RFC-006/007's checkout token cannot be reused to gate the tickets page:
-- `src/features/payments/api.ts` already documents, as an accepted RFC-007
-- tradeoff, that the raw checkout token travels inside the Mercado Pago
-- `back_urls` and is therefore RETAINED by a third party (Mercado Pago's
-- own preference records). That exposure is acceptable for a short-lived
-- "check my payment status" credential; it is NOT acceptable for a
-- long-lived credential that unlocks scannable venue-entry QR codes.
-- RFC-008 therefore mints a SEPARATE, distinct capability that never
-- leaves Lucky Ticket's own servers: a stateless
-- `hmac-sha256(TICKET_ACCESS_SIGNING_KEY, "order:" || orderId)` value,
-- computed in `src/lib/tickets/access-token.ts` and handed to the buyer by
-- extending the EXISTING `GET /api/orders/[orderId]/payment-status`
-- response (no new endpoint - see RFC-007's own "reuse existing
-- infrastructure" precedent) the moment the order's status folds to PAID.
-- Because it is a deterministic function of a fixed server secret and the
-- order id, it needs NO database storage and creates NO minting race: any
-- server request can recompute and verify it at any time, independent of
-- which process (webhook handler vs. buyer's browser) asks first - this
-- was chosen specifically to avoid the unrecoverable-lockout race a
-- stored-random-token design would create (the webhook handler that would
-- mint such a token has no channel back to the buyer's browser).
--
-- This migration's `get_order_tickets` function does NOT re-verify that
-- HMAC itself; it is granted to `service_role` ONLY, exactly like
-- `confirm_order_payment` (RFC-007 section 53's "narrow interface is
-- itself sufficient authorization" precedent, applied to a read instead
-- of a write) - the ONLY caller able to reach it at all is trusted
-- server-side code that has ALREADY verified the buyer's capability
-- token in Node before ever touching the database, the same split-trust
-- shape `confirm_order_payment` already uses for the webhook signature
-- (verified in Node, never re-derived in SQL).
--
-- ============================================================================
-- MULTI-TENANCY & NO CLIENT TRUST
-- ============================================================================
-- `issue_tickets_for_order` never accepts ticket_type_id/quantity/price/
-- event_id/organization_id/status/QR data as input - every value is
-- derived exclusively from `orders`/`order_items`/`ticket_types` rows
-- already tied together by RFC-002's composite
-- `(organization_id, id)` foreign keys. Every new `tickets` row is
-- produced by copying `organization_id`/`event_id`/`ticket_type_id`
-- straight off the matching `order_items`/`orders` row, so a ticket can
-- never end up attached to the wrong tenant, event, or ticket type - the
-- same composite-FK pattern RFC-002 already established for `tickets`
-- itself is what makes this a schema-level guarantee, not just an
-- application-level one.

-- Defensive/idempotent only: a real Supabase project already has pgcrypto
-- installed (typically in its own `extensions` schema, per Supabase's own
-- convention - see the `with schema extensions` pattern RFC-007's own
-- test file already uses for pgtap), so this is normally a no-op. Every
-- new function below that calls a pgcrypto function
-- (gen_random_bytes/digest/pgp_sym_encrypt/pgp_sym_decrypt) explicitly
-- adds `extensions` to its own `search_path`, rather than assuming
-- pgcrypto landed in `public` - see "BACKWARD COMPATIBILITY & REAL-SUPABASE
-- FIXES" below for why this matters.
create extension if not exists pgcrypto;

-- ============================================================================
-- BACKWARD COMPATIBILITY & REAL-SUPABASE FIXES (read this before the
-- column/function definitions below)
-- ============================================================================
-- This section documents two corrections made after this migration was
-- first validated only against a disposable, from-scratch native
-- PostgreSQL instance (no Docker available) and was then run for real
-- against a genuine local Supabase stack, which surfaced two real bugs:
--
-- 1. `tickets.ticket_sequence`/`qr_secret_ciphertext` must be NULLABLE,
--    not NOT NULL. `supabase/tests/database/rfc_002_security.test.sql`
--    (a HISTORICAL, unmodifiable RFC-002 test) inserts directly into
--    `public.tickets` to fixture a row for its own RLS assertions,
--    predating RFC-008 and supplying neither column. The substitute
--    from-scratch Postgres instance used during authoring never ran that
--    test file, so this was missed there; a real `supabase test db` run
--    against the full historical suite caught it immediately. The fix:
--    both new columns are nullable, exactly like RFC-002's own
--    `qr_token_hash` already is ("every not-yet-issued ticket will have
--    [null]") - a `check` constraint (`tickets_sequence_ciphertext_together`
--    below) carries the REAL invariant instead: an RFC-008-issued ticket
--    always has both together, never just one. A hand-inserted fixture
--    row simply leaves both null, same as it always could for
--    `qr_token_hash`.
--
-- 2. `gen_random_bytes`/`digest`/`pgp_sym_decrypt` are pgcrypto functions
--    that, on a real Supabase project, typically live in the `extensions`
--    schema, not `public` - and every function below runs with an
--    explicit `set search_path = public, ...` (the estabished
--    SECURITY DEFINER convention in this codebase, to avoid a
--    search-path-injection attack surface), which does NOT implicitly
--    include `extensions`. `gen_random_uuid()` masked this during
--    authoring: it has been a PostgreSQL core/`pg_catalog` builtin since
--    PG13 (always reachable regardless of search_path), so its use
--    elsewhere in this schema never exposed the gap - but true pgcrypto
--    functions like `gen_random_bytes` are not core builtins. The fix:
--    `issue_tickets_for_order` and `get_order_tickets` (the two functions
--    that actually call pgcrypto functions directly) both add
--    `extensions` to their own `search_path`.
--
-- Both are called out explicitly, rather than silently fixed, because
-- they are a direct, honest consequence of not having Docker available to
-- run a real local Supabase stack while first authoring this migration -
-- see docs/rfcs/RFC-008-ticketing.md "Validation results" for the full
-- account of what substitute validation could and could not catch.

-- ============================================================================
-- tickets: new columns for idempotent issuance + QR redisplay
-- ============================================================================

-- NULLABLE, deliberately - see "BACKWARD COMPATIBILITY" below. A CHECK
-- constraint (not NOT NULL) is what actually carries RFC-008's invariant:
-- these two new columns are always populated TOGETHER by
-- issue_tickets_for_order, or left null together on any row this
-- migration did not create (a hand-inserted fixture row from an earlier
-- RFC's own test file, or any future manually-created row that
-- intentionally predates issuance) - exactly the same nullability
-- pattern RFC-002 already established for qr_token_hash ("every
-- not-yet-issued ticket will have [null]").
alter table public.tickets
  add column ticket_sequence integer,
  add column qr_secret_ciphertext bytea,
  add column qr_secret_version smallint not null default 1;

alter table public.tickets
  add constraint tickets_ticket_sequence_positive check (ticket_sequence > 0);

alter table public.tickets
  add constraint tickets_sequence_ciphertext_together
    check ((ticket_sequence is null) = (qr_secret_ciphertext is null));

-- The idempotency backbone (see "IDEMPOTENCY & CONCURRENCY" above): at
-- most one ticket may ever occupy a given (order_item, sequence) slot.
-- Multiple NULL ticket_sequence rows (legacy/hand-inserted fixtures) do
-- NOT conflict with each other or with this constraint - a standard SQL
-- unique constraint never treats NULL as equal to NULL.
alter table public.tickets
  add constraint tickets_org_item_seq_key
    unique (organization_id, order_item_id, ticket_sequence);

comment on table public.tickets is
  'ticket_number is a display/reference identifier only - it grants no authorization. qr_token_hash stores a one-way hash of the per-ticket QR secret (sha256), used for RFC-009 scan-time validation; qr_secret_ciphertext stores the SAME raw secret encrypted (pgp_sym_encrypt, key supplied only as a per-call argument, never persisted) so the issuing server can re-render the QR for the buyer without ever storing the raw value. Neither column, alone or together with a database leak, yields a usable raw QR secret without the encryption key, which lives only in a server env var. Issuance (RFC-008) is performed exclusively by issue_tickets_for_order, called from confirm_order_payment (RFC-007) the instant an order reaches PAID.';

comment on column public.tickets.ticket_sequence is
  'RFC-008: 1-based position of this ticket within its order_item (1..order_items.quantity). Combined with order_item_id, this is the deterministic "slot" identity that makes issuance idempotent under concurrent/repeated calls - see tickets_org_item_seq_key.';

comment on column public.tickets.qr_secret_ciphertext is
  'RFC-008: pgp_sym_encrypt(raw QR secret, key, ''cipher-algo=aes256''). The encryption key is never stored in this database; it is supplied as a plain argument to issue_tickets_for_order/get_order_tickets by trusted server code (src/lib/env/server.ts''s getTicketServerEnv). A database leak alone never yields a usable raw QR secret.';

comment on column public.tickets.qr_secret_version is
  'RFC-008: versions the QR secret''s encryption scheme (currently always 1 = pgp_sym_encrypt/aes256), so a future key-rotation or AEAD migration can distinguish old vs. new rows without a backfill.';

-- ============================================================================
-- issue_tickets_for_order: atomic, idempotent, concurrency-safe issuance
-- ============================================================================
-- Preconditioned on the order already being in a state that implies a
-- completed payment (PAID, or REFUNDED/PARTIALLY_REFUNDED - a refund can
-- only ever happen to an order that was PAID first, so tickets must
-- already exist for those too; RFC-008 does not implement refund-driven
-- ticket cancellation, but must not BLOCK that future path either - see
-- docs/rfcs/RFC-008-ticketing.md "Future work"). Returns the number of
-- ticket rows this specific call newly inserted (0 on every idempotent
-- repeat call) purely for caller-side diagnostics/logging - callers must
-- never branch application logic on this count being nonzero.
create function public.issue_tickets_for_order(
  p_order_id uuid,
  p_qr_encryption_key text
)
returns integer
language plpgsql
security definer
-- `extensions` added: this function calls gen_random_bytes/digest/
-- pgp_sym_encrypt directly, which are pgcrypto functions that live in the
-- `extensions` schema on a real Supabase project, not `public` - see
-- "BACKWARD COMPATIBILITY & REAL-SUPABASE FIXES" above.
set search_path = public, extensions, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_inserted integer;
begin
  if p_order_id is null then
    raise exception 'order id is required' using errcode = 'LT020';
  end if;

  if btrim(coalesce(p_qr_encryption_key, '')) = '' then
    raise exception 'qr encryption key is required' using errcode = 'LT020';
  end if;

  -- Lock the order row. When called from within confirm_order_payment
  -- (the normal path) this row is already locked by that same
  -- transaction's earlier `for update` - re-acquiring the same row lock
  -- in the same transaction is a no-op, never a deadlock. When called
  -- standalone (pgTAP tests, manual reconciliation), this is what makes
  -- the function safe to call concurrently on its own.
  select o.* into v_order from public.orders o where o.id = p_order_id for update;

  if not found then
    raise exception 'order not found' using errcode = 'LT020';
  end if;

  -- Payment-state gating: only an order that has definitely been paid may
  -- ever have tickets issued for it. PENDING_PAYMENT, PAYMENT_FAILED,
  -- CANCELLED, and EXPIRED are all explicitly rejected.
  if v_order.status not in ('PAID', 'REFUNDED', 'PARTIALLY_REFUNDED') then
    raise exception 'order is not paid' using errcode = 'LT021';
  end if;

  -- One atomic statement: for every order_item on this order, generate
  -- `quantity` candidate ticket slots (sequence 1..quantity), each with
  -- its own fresh id, CSPRNG-generated raw QR secret, its sha256 hash,
  -- and its pgp_sym_encrypt ciphertext - then let the unique constraint
  -- on (organization_id, order_item_id, ticket_sequence) silently drop
  -- any slot that already has a row (ON CONFLICT DO NOTHING). This is
  -- what makes repeated/concurrent calls converge to exactly one row per
  -- slot regardless of how many times or how concurrently this statement
  -- runs.
  with candidate as (
    select
      gen_random_uuid() as id,
      oi.organization_id,
      v_order.event_id,
      oi.order_id,
      oi.id as order_item_id,
      oi.ticket_type_id,
      seq.n as ticket_sequence,
      encode(gen_random_bytes(32), 'hex') as raw_qr_token
    from public.order_items oi
    cross join lateral generate_series(1, oi.quantity) as seq(n)
    where oi.organization_id = v_order.organization_id
      and oi.order_id = v_order.id
  )
  insert into public.tickets (
    id, organization_id, event_id, order_id, order_item_id, ticket_type_id,
    ticket_number, ticket_sequence, qr_token_hash, qr_secret_ciphertext,
    qr_secret_version, status, issued_at
  )
  select
    c.id,
    c.organization_id,
    c.event_id,
    c.order_id,
    c.order_item_id,
    c.ticket_type_id,
    -- Display-only identifier. Derived from this row's own fresh id
    -- (globally unique by the same guarantee as any UUID primary key in
    -- this schema) rather than needing to be independently deterministic -
    -- once a slot's first successful insert wins, its ticket_number is
    -- fixed forever; a losing concurrent attempt's generated number is
    -- simply discarded along with the rest of that row.
    upper(replace(c.id::text, '-', '')),
    c.ticket_sequence,
    encode(digest(c.raw_qr_token, 'sha256'), 'hex'),
    pgp_sym_encrypt(c.raw_qr_token, p_qr_encryption_key, 'cipher-algo=aes256'),
    1,
    'VALID',
    now()
  from candidate c
  on conflict (organization_id, order_item_id, ticket_sequence) do nothing;

  get diagnostics v_inserted = row_count;

  return v_inserted;
end;
$$;

comment on function public.issue_tickets_for_order(uuid, text) is
  'RFC-008 core issuance. SECURITY DEFINER, service_role EXECUTE only. Preconditioned on orders.status in (PAID, REFUNDED, PARTIALLY_REFUNDED). Idempotent and concurrency-safe via unique(organization_id, order_item_id, ticket_sequence) + ON CONFLICT DO NOTHING inside one INSERT...SELECT - never via an application-level existence check. Never accepts ticket_type_id/quantity/price/event_id/organization_id from its caller; every value is derived from order_items/orders. Raises (errcode LT020/LT021) rather than silently doing nothing on a missing order or a non-payable status - callers that want failures isolated from a larger transaction must use issue_tickets_for_order_safe instead.';

revoke all on function public.issue_tickets_for_order(uuid, text) from public;
revoke all on function public.issue_tickets_for_order(uuid, text) from anon;
revoke all on function public.issue_tickets_for_order(uuid, text) from authenticated;
grant execute on function public.issue_tickets_for_order(uuid, text) to service_role;

-- ============================================================================
-- issue_tickets_for_order_safe: never lets an issuance bug undo a PAID
-- transition
-- ============================================================================
-- Called from inside confirm_order_payment's own transaction, immediately
-- after the order is transitioned to PAID. A `begin ... exception when
-- others` block in plpgsql implicitly opens a savepoint: if
-- issue_tickets_for_order raises for ANY reason (a future bug, a
-- constraint violation this migration didn't anticipate, ...), only the
-- work done since that savepoint is rolled back - the PAID transition
-- and every payment/audit row confirm_order_payment already wrote stay
-- committed. The failure is instead recorded as a diagnosable audit_logs
-- entry ("payment approved but tickets missing" - see RFC-008 section on
-- observability) rather than corrupting payment truth.
create function public.issue_tickets_for_order_safe(
  p_order_id uuid,
  p_qr_encryption_key text
)
returns void
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_inserted integer;
  v_organization_id uuid;
begin
  begin
    v_inserted := public.issue_tickets_for_order(p_order_id, p_qr_encryption_key);
  exception when others then
    select o.organization_id into v_organization_id
      from public.orders o
      where o.id = p_order_id;

    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_organization_id,
      'tickets_issuance_failed',
      'order',
      p_order_id,
      -- Never log the QR encryption key or any raw QR secret - only
      -- the SQLSTATE/SQLERRM diagnostic, which describes the failure
      -- without exposing any secret value.
      jsonb_build_object('sqlstate', sqlstate, 'message', sqlerrm)
    );

    return;
  end;

  if v_inserted > 0 then
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    select o.organization_id, 'tickets_issued', 'order', p_order_id,
      jsonb_build_object('orderId', p_order_id, 'ticketCount', v_inserted)
    from public.orders o
    where o.id = p_order_id;
  end if;
end;
$$;

comment on function public.issue_tickets_for_order_safe(uuid, text) is
  'RFC-008: exception-isolating wrapper around issue_tickets_for_order. Never raises - a failure is recorded as a tickets_issuance_failed audit_logs row (SQLSTATE/SQLERRM only, never the encryption key or any raw QR secret) so confirm_order_payment''s own PAID transition is never rolled back by an issuance bug. This is the function confirm_order_payment actually calls; issue_tickets_for_order itself is called directly only by pgTAP tests and any future manual-reconciliation tooling that wants issuance failures to be visible as a raised exception.';

revoke all on function public.issue_tickets_for_order_safe(uuid, text) from public;
revoke all on function public.issue_tickets_for_order_safe(uuid, text) from anon;
revoke all on function public.issue_tickets_for_order_safe(uuid, text) from authenticated;
grant execute on function public.issue_tickets_for_order_safe(uuid, text) to service_role;

-- ============================================================================
-- confirm_order_payment (redefined): calls issue_tickets_for_order_safe
-- ============================================================================
-- DROP is required (not CREATE OR REPLACE) because the parameter list is
-- changing (a new p_qr_encryption_key argument) - the same "signature
-- change requires DROP + CREATE, migration FILE stays untouched"
-- convention RFC-007 already used for get_checkout_order. Every line of
-- RFC-007's own payment-truth logic below is otherwise BYTE-FOR-BYTE
-- unchanged from 20260925000000_rfc_007_mercado_pago.sql; only the new
-- parameter and the single `perform issue_tickets_for_order_safe(...)`
-- call (placed immediately after the order is transitioned to PAID) are
-- new.
drop function if exists public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid);

create function public.confirm_order_payment(
  p_order_id uuid,
  p_provider public.payment_provider,
  p_provider_payment_id text,
  p_status public.payment_status,
  p_paid_amount_minor bigint,
  p_currency char(3),
  p_payment_method text,
  p_provider_payload jsonb,
  p_approved_at timestamptz,
  p_webhook_event_id uuid,
  -- DEFAULT NULL, deliberately: RFC-007's own historical test file
  -- (supabase/tests/database/rfc_007_payments.test.sql) calls this
  -- function with its ORIGINAL 10-argument signature in 14 places, and
  -- that file must never be modified. A trailing parameter with a
  -- default lets PostgreSQL resolve BOTH the legacy 10-argument call
  -- (this defaults to null) and the new 11-argument call
  -- (src/features/payments/webhook.ts always passes it explicitly) as
  -- the SAME single function - no overload, no ambiguity. A null key
  -- simply means "issuance is skipped and recorded as a diagnosable
  -- audit_logs failure" (see issue_tickets_for_order_safe below) rather
  -- than an error a legacy caller was never written to expect - RFC-007's
  -- own payment-truth assertions are about confirming payments, not
  -- about ticket issuance, so this is the correct behavior for them.
  p_qr_encryption_key text default null
)
returns table (
  outcome text,
  order_id uuid,
  order_status text,
  payment_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_existing_payment_id uuid;
  v_existing_payment_status public.payment_status;
  v_payment_id uuid;
  v_item record;
  v_committed bigint;
  v_held bigint;
  v_capacity integer;
  v_available bigint;
  v_inventory_ok boolean := true;
  v_late_recovery boolean := false;
begin
  if p_order_id is null or btrim(coalesce(p_provider_payment_id, '')) = '' then
    raise exception 'order and provider payment id are required' using errcode = 'LT010';
  end if;

  select o.* into v_order from public.orders o where o.id = p_order_id for update;

  if not found then
    raise exception 'order not found for payment' using errcode = 'LT010';
  end if;

  select id, status into v_existing_payment_id, v_existing_payment_status
    from public.payments
    where provider = p_provider and provider_payment_id = p_provider_payment_id;

  if found then
    return query select 'ALREADY_PROCESSED'::text, v_order.id, v_order.status::text, v_existing_payment_id;
    return;
  end if;

  begin
    insert into public.payments (
      organization_id, order_id, provider, provider_payment_id,
      status, paid_amount, currency, payment_method, provider_payload, approved_at
    ) values (
      v_order.organization_id, v_order.id, p_provider, p_provider_payment_id,
      p_status, p_paid_amount_minor, p_currency, p_payment_method,
      coalesce(p_provider_payload, '{}'::jsonb), p_approved_at
    )
    returning id into v_payment_id;
  exception when unique_violation then
    select id into v_payment_id
      from public.payments
      where provider = p_provider and provider_payment_id = p_provider_payment_id;

    return query select 'ALREADY_PROCESSED'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end;

  if p_webhook_event_id is not null then
    update public.webhook_events
      set status = 'PROCESSED', processed_at = now()
      where id = p_webhook_event_id;
  end if;

  if p_status <> 'APPROVED' then
    return query select 'RECORDED_NOT_APPROVED'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  if v_order.status = 'PAID' then
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_order.organization_id, 'payment_approved_order_already_paid', 'order', v_order.id,
      jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'paymentId', v_payment_id)
    );
    return query select 'ORDER_ALREADY_PAID'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  if v_order.status not in ('PENDING_PAYMENT', 'EXPIRED') then
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_order.organization_id, 'payment_approved_order_not_payable', 'order', v_order.id,
      jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'orderStatus', v_order.status, 'paymentId', v_payment_id)
    );
    return query select 'REJECTED_ORDER_STATE'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  if p_currency <> v_order.currency then
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_order.organization_id, 'payment_currency_mismatch', 'order', v_order.id,
      jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'orderCurrency', v_order.currency, 'paymentCurrency', p_currency, 'paymentId', v_payment_id)
    );
    return query select 'REJECTED_CURRENCY_MISMATCH'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  if p_paid_amount_minor <> v_order.total_amount then
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_order.organization_id, 'payment_amount_mismatch', 'order', v_order.id,
      jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'orderTotalAmount', v_order.total_amount, 'paymentAmount', p_paid_amount_minor, 'paymentId', v_payment_id)
    );
    return query select 'REJECTED_AMOUNT_MISMATCH'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  v_late_recovery := not (v_order.status = 'PENDING_PAYMENT' and v_order.expires_at > now());

  if v_late_recovery then
    for v_item in
      select oi.ticket_type_id, oi.quantity
        from public.order_items oi
        where oi.organization_id = v_order.organization_id
          and oi.order_id = v_order.id
        order by oi.ticket_type_id
    loop
      perform 1 from public.ticket_types tt where tt.id = v_item.ticket_type_id for update;

      select tt.quantity into v_capacity
        from public.ticket_types tt
        where tt.id = v_item.ticket_type_id;

      select coalesce(sum(oi2.quantity), 0) into v_committed
        from public.order_items oi2
        join public.orders o2
          on o2.organization_id = oi2.organization_id
         and o2.id = oi2.order_id
        where oi2.organization_id = v_order.organization_id
          and oi2.ticket_type_id = v_item.ticket_type_id
          and o2.status = 'PAID';

      select coalesce(sum(h.quantity), 0) into v_held
        from public.ticket_holds h
        join public.orders o3
          on o3.organization_id = h.organization_id
         and o3.id = h.order_id
        where h.organization_id = v_order.organization_id
          and h.ticket_type_id = v_item.ticket_type_id
          and o3.status = 'PENDING_PAYMENT'
          and h.expires_at > now()
          and o3.id <> v_order.id;

      v_available := v_capacity::bigint - v_committed - v_held;

      if v_item.quantity > v_available then
        v_inventory_ok := false;
        exit;
      end if;
    end loop;

    if not v_inventory_ok then
      insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
      values (
        v_order.organization_id, 'payment_approved_inventory_unavailable', 'order', v_order.id,
        jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'paymentId', v_payment_id)
      );
      return query select 'REJECTED_INVENTORY_UNAVAILABLE'::text, v_order.id, v_order.status::text, v_payment_id;
      return;
    end if;
  end if;

  update public.orders
    set status = 'PAID', paid_at = coalesce(p_approved_at, now())
    where id = v_order.id;

  insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
  values (
    v_order.organization_id,
    case when v_late_recovery then 'order_paid_late_recovery' else 'order_paid' end,
    'order', v_order.id,
    jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'paymentId', v_payment_id)
  );

  -- RFC-008: issue exactly one ticket per purchased unit now that this
  -- order has authoritatively reached PAID. Isolated via the "_safe"
  -- wrapper so a ticketing bug can never roll back the payment
  -- confirmation above - see this migration's header comment.
  perform public.issue_tickets_for_order_safe(v_order.id, p_qr_encryption_key);

  return query select
    (case when v_late_recovery then 'PAID_LATE_RECOVERY' else 'PAID' end)::text,
    v_order.id, 'PAID'::text, v_payment_id;
end;
$$;

comment on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid, text) is
  'RFC-007 payment-truth boundary, extended by RFC-008 to issue tickets (via issue_tickets_for_order_safe) in the SAME transaction as the PAID transition. SECURITY DEFINER, service_role EXECUTE only - never anon/authenticated. Locks the order row first, is idempotent per (provider, provider_payment_id), independently validates order state/currency/amount before any PAID transition, re-verifies inventory capacity before a late/expired-window recovery, and now also guarantees "PAID implies tickets exist" as a single atomic unit - a bug in ticket issuance can never undo a genuine payment confirmation. p_qr_encryption_key is passed through untouched to issuance; it is never persisted by this function.';

revoke all on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid, text) from public;
revoke all on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid, text) from anon;
revoke all on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid, text) from authenticated;
grant execute on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid, text) to service_role;

-- ============================================================================
-- get_order_tickets: the buyer-facing tickets read boundary
-- ============================================================================
-- Granted to service_role ONLY - exactly like confirm_order_payment. The
-- ONLY code able to call this at all is trusted server-side code
-- (src/features/tickets/queries.ts, using the service-role client already
-- established by RFC-007 for webhook processing) that has ALREADY
-- verified the buyer's ticket-access capability (an HMAC computed in
-- src/lib/tickets/access-token.ts) BEFORE ever reaching this function -
-- an order id alone, or a bare Postgres credential without that prior
-- Node-side verification, is never sufficient. Requires the order to be
-- in a state that implies a completed payment (mirrors
-- issue_tickets_for_order's own precondition, since a REFUNDED/
-- PARTIALLY_REFUNDED order necessarily passed through PAID and issuance
-- first).
create function public.get_order_tickets(
  p_order_id uuid,
  p_qr_encryption_key text
)
returns table (
  ticket_id uuid,
  ticket_number text,
  ticket_status text,
  ticket_type_name text,
  qr_raw_token text,
  issued_at timestamptz,
  checked_in_at timestamptz,
  order_status text,
  event_name text,
  event_starts_at timestamptz,
  event_venue_name text,
  organization_name text
)
language plpgsql
security definer
-- `extensions` added: this function calls pgp_sym_decrypt directly - see
-- "BACKWARD COMPATIBILITY & REAL-SUPABASE FIXES" above.
set search_path = public, extensions, pg_temp
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_order_id is null then
    raise exception 'order id is required' using errcode = 'LT022';
  end if;

  if btrim(coalesce(p_qr_encryption_key, '')) = '' then
    raise exception 'qr encryption key is required' using errcode = 'LT022';
  end if;

  select o.* into v_order from public.orders o where o.id = p_order_id;

  if not found or v_order.status not in ('PAID', 'REFUNDED', 'PARTIALLY_REFUNDED') then
    -- Deliberately the SAME exception/errcode for "no such order" and
    -- "order exists but was never paid" - never let a caller distinguish
    -- the two (same not-found-boundary convention RFC-006/007 already use
    -- for an invalid checkout token).
    raise exception 'order not found or not paid' using errcode = 'LT022';
  end if;

  return query
    select
      t.id,
      t.ticket_number,
      t.status::text,
      tt.name,
      pgp_sym_decrypt(t.qr_secret_ciphertext, p_qr_encryption_key),
      t.issued_at,
      t.checked_in_at,
      v_order.status::text,
      e.name,
      e.starts_at,
      e.venue_name,
      org.name
    from public.tickets t
    join public.ticket_types tt
      on tt.organization_id = t.organization_id and tt.id = t.ticket_type_id
    join public.events e
      on e.organization_id = v_order.organization_id and e.id = v_order.event_id
    join public.organizations org
      on org.id = v_order.organization_id
    where t.organization_id = v_order.organization_id
      and t.order_id = v_order.id
    order by t.ticket_sequence, t.order_item_id;
end;
$$;

comment on function public.get_order_tickets(uuid, text) is
  'RFC-008 buyer-facing tickets read boundary. SECURITY DEFINER, service_role EXECUTE only - the trusted Node caller (src/features/tickets/queries.ts) must have ALREADY verified the buyer''s ticket-access HMAC capability before calling this function; an order id alone never authorizes anything here. Requires orders.status in (PAID, REFUNDED, PARTIALLY_REFUNDED). Decrypts each ticket''s QR secret on the fly via pgp_sym_decrypt using a key supplied only as a call argument - the raw secret is never persisted and is returned here only to the one already-authorized request that needs to render a QR image.';

revoke all on function public.get_order_tickets(uuid, text) from public;
revoke all on function public.get_order_tickets(uuid, text) from anon;
revoke all on function public.get_order_tickets(uuid, text) from authenticated;
grant execute on function public.get_order_tickets(uuid, text) to service_role;

-- ============================================================================
-- reconcile_missing_tickets: durable, retryable recovery for "PAID with
-- missing tickets"
-- ============================================================================
-- issue_tickets_for_order_safe (above) deliberately swallows an issuance
-- failure so a bug there can never undo a genuine payment confirmation
-- (invariant A: never lose a real payment). On its own that is only half
-- the story - invariant B is "never leave PAID + missing tickets
-- silently unrecoverable." The tickets_issuance_failed audit_logs row
-- issue_tickets_for_order_safe writes is what makes the situation
-- DETECTABLE; this function is what makes it RECOVERABLE, without any
-- new infrastructure (no queue, no worker, no scheduler - a plain
-- SECURITY DEFINER function, callable by service_role like everything
-- else in this migration, safe to invoke manually or from a future
-- scheduled job).
--
-- Scans every order whose payment succeeded (PAID, or
-- REFUNDED/PARTIALLY_REFUNDED - both necessarily passed through PAID
-- first) where its actual ticket count is less than
-- sum(order_items.quantity), and re-attempts issuance for each. This is
-- safe to run at any time, repeatedly, for the same reason
-- issue_tickets_for_order itself is idempotent: an order that already has
-- all its tickets is simply never selected by the where clause below, and
-- one that is only partially issued (should never happen given
-- issue_tickets_for_order's own all-in-one-statement design, but the
-- query does not assume that) converges to fully issued via the same
-- ON CONFLICT DO NOTHING mechanism.
--
-- Each order is isolated in its own exception block (the same savepoint
-- technique as issue_tickets_for_order_safe) so ONE order with a
-- persistent, unresolved problem (e.g. a genuinely corrupted row) can
-- never block reconciling every other order in the same run.
create function public.reconcile_missing_tickets(
  p_qr_encryption_key text
)
returns table (
  order_id uuid,
  status text,
  tickets_issued integer
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order_id uuid;
  v_count integer;
begin
  if btrim(coalesce(p_qr_encryption_key, '')) = '' then
    raise exception 'qr encryption key is required' using errcode = 'LT023';
  end if;

  for v_order_id in
    select o.id
      from public.orders o
      where o.status in ('PAID', 'REFUNDED', 'PARTIALLY_REFUNDED')
        and coalesce((
          select sum(oi.quantity)
            from public.order_items oi
            where oi.organization_id = o.organization_id and oi.order_id = o.id
        ), 0) > (
          select count(*)
            from public.tickets t
            where t.organization_id = o.organization_id and t.order_id = o.id
        )
      order by o.paid_at nulls last, o.id
  loop
    begin
      v_count := public.issue_tickets_for_order(v_order_id, p_qr_encryption_key);
      order_id := v_order_id;
      status := 'ISSUED';
      tickets_issued := v_count;
      return next;
    exception when others then
      insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
      select o.organization_id, 'tickets_issuance_failed', 'order', v_order_id,
        jsonb_build_object('sqlstate', sqlstate, 'message', sqlerrm, 'source', 'reconcile_missing_tickets')
        from public.orders o where o.id = v_order_id;

      order_id := v_order_id;
      status := 'FAILED';
      tickets_issued := 0;
      return next;
    end;
  end loop;
end;
$$;

comment on function public.reconcile_missing_tickets(text) is
  'RFC-008: durable, idempotent, manually/operator-invokable recovery for "PAID order with missing tickets" (invariant B - detectable via tickets_issuance_failed audit_logs rows, recoverable via this function). Never fails an entire reconciliation run because of one bad order - each order is isolated in its own exception block. Safe to call repeatedly/on a schedule; an order with no missing tickets is never selected. service_role EXECUTE only.';

revoke all on function public.reconcile_missing_tickets(text) from public;
revoke all on function public.reconcile_missing_tickets(text) from anon;
revoke all on function public.reconcile_missing_tickets(text) from authenticated;
grant execute on function public.reconcile_missing_tickets(text) to service_role;
