-- RFC-008 database test suite (pgTAP): Ticket Issuance & Secure QR.
--
-- Exercises supabase/migrations/<ts>_rfc_008_ticketing.sql:
-- issue_tickets_for_order, issue_tickets_for_order_safe, the redefined
-- confirm_order_payment (now issuing tickets), and get_order_tickets.
-- Does NOT re-test anything RFC-002/006/007 already cover (RLS role
-- lists, checkout-token authorization, currency/amount/inventory
-- validation, webhook idempotency plumbing) - those are unchanged by this
-- migration; see rfc_007_payments.test.sql for that coverage.
--
-- Auth simulation: same pattern as every prior RFC test file -
-- `set_config('request.jwt.claim.sub', ...)` + `set local role`
-- reproduces exactly what PostgREST sets per request.
--
-- A note on transaction boundaries (same reasoning as RFC-006/007's test
-- files): assertions that expect a function to RAISE go through pgTAP's
-- `throws_ok()`, which wraps the call in its own SAVEPOINT internally - a
-- bare failing call inside this file's own `begin ... rollback` would
-- abort the entire test transaction on the first expected failure.
--
-- True concurrent-connection testing (two overlapping transactions racing
-- issue_tickets_for_order's unique constraint) cannot be exercised inside
-- this single pgTAP transaction/connection - see
-- scripts/rfc-008-concurrency-test.sh, which proves that scenario with two
-- real, concurrent psql connections against a running local stack.
--
-- Run via the Supabase CLI once a local stack is available:
--   supabase test db

begin;

create extension if not exists pgtap with schema extensions;

select plan(63);

-- A fixed, obviously-fake key used only within this test transaction -
-- never a real secret, never logged, exists only to exercise
-- pgp_sym_encrypt/pgp_sym_decrypt round-tripping deterministically.
\set qr_key 'test-only-qr-encryption-key-0123456789abcdef'

-- =============================================================================
-- SECTION A: function privileges (pure catalog state, no fixtures needed)
-- =============================================================================

select ok(
  not has_function_privilege('anon', (select oid from pg_proc where proname = 'issue_tickets_for_order' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '01: anon has NO EXECUTE privilege on issue_tickets_for_order'
);

select ok(
  not has_function_privilege('authenticated', (select oid from pg_proc where proname = 'issue_tickets_for_order' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '02: authenticated has NO EXECUTE privilege on issue_tickets_for_order'
);

select ok(
  has_function_privilege('service_role', (select oid from pg_proc where proname = 'issue_tickets_for_order' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '03: service_role has EXECUTE on issue_tickets_for_order (its only intended caller)'
);

select ok(
  not has_function_privilege('anon', (select oid from pg_proc where proname = 'get_order_tickets' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '04: anon has NO EXECUTE privilege on get_order_tickets - an order id alone must never read tickets'
);

select ok(
  not has_function_privilege('authenticated', (select oid from pg_proc where proname = 'get_order_tickets' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '05: authenticated has NO EXECUTE privilege on get_order_tickets either'
);

select ok(
  has_function_privilege('service_role', (select oid from pg_proc where proname = 'get_order_tickets' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '06: service_role has EXECUTE on get_order_tickets'
);

select ok(
  has_function_privilege('service_role', (select oid from pg_proc where proname = 'confirm_order_payment' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '07: service_role still has EXECUTE on the redefined (11-arg) confirm_order_payment'
);

-- Schema-level QR-secret invariants: no column anywhere on tickets can
-- hold a raw/plaintext secret - only a one-way hash (text) and an
-- encrypted ciphertext (bytea).
select ok(
  (select data_type from information_schema.columns where table_schema = 'public' and table_name = 'tickets' and column_name = 'qr_secret_ciphertext') = 'bytea',
  '08: tickets.qr_secret_ciphertext is bytea (encrypted), not text'
);

select ok(
  (select count(*)::int from information_schema.columns where table_schema = 'public' and table_name = 'tickets' and column_name in ('qr_secret_raw', 'qr_token', 'qr_secret')) = 0,
  '09: no column named like a raw/plaintext QR secret exists on tickets'
);

-- =============================================================================
-- SECTION B: fixtures
-- =============================================================================

insert into auth.users (id, email) values
  ('08000000-0000-0000-0000-000000000001', 'owner-a@example.test'),
  ('08000000-0000-0000-0000-000000000002', 'owner-b@example.test');

insert into public.organizations (id, name, slug, currency, timezone) values
  ('08a00000-0000-0000-0000-00000000000a', 'RFC-008 Org A', 'rfc008-org-a', 'ARS', 'America/Argentina/Buenos_Aires'),
  ('08a00000-0000-0000-0000-00000000000b', 'RFC-008 Org B', 'rfc008-org-b', 'ARS', 'America/Argentina/Buenos_Aires');

insert into public.organization_members (organization_id, user_id, role) values
  ('08a00000-0000-0000-0000-00000000000a', '08000000-0000-0000-0000-000000000001', 'OWNER'),
  ('08a00000-0000-0000-0000-00000000000b', '08000000-0000-0000-0000-000000000002', 'OWNER');

insert into public.events (id, organization_id, name, slug, starts_at, venue_name, status) values
  ('08e00000-0000-0000-0000-000000000001', '08a00000-0000-0000-0000-00000000000a', 'RFC-008 Show', 'rfc008-show', now() + interval '30 days', 'Teatro Colon', 'DRAFT'),
  ('08e00000-0000-0000-0000-00000000000b', '08a00000-0000-0000-0000-00000000000b', 'RFC-008 Org B Show', 'rfc008-org-b-show', now() + interval '30 days', 'Estadio B', 'DRAFT');

insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('08c00000-0000-0000-0000-000000000001', '08a00000-0000-0000-0000-00000000000a', '08e00000-0000-0000-0000-000000000001', 'General', 100000, 'ARS', 50, 'PUBLIC', true),
  ('08c00000-0000-0000-0000-000000000002', '08a00000-0000-0000-0000-00000000000a', '08e00000-0000-0000-0000-000000000001', 'VIP', 200000, 'ARS', 50, 'PUBLIC', true);

update public.events set status = 'PUBLISHED' where id = '08e00000-0000-0000-0000-000000000001';

-- ---------------------------------------------------------------------------
-- Order 1: a single order_item, quantity 1 (qty 1 -> 1 ticket).
-- ---------------------------------------------------------------------------
select order_id, total_amount
  into temporary t_order_qty1
  from public.create_order_with_hold(
    'rfc008-org-a', 'rfc008-show',
    '[{"ticketTypeId": "08c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Buyer One', 'buyer1@example.test', null,
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  );

-- ---------------------------------------------------------------------------
-- Order 2: a single order_item, quantity 5 (qty 5 -> 5 tickets).
-- ---------------------------------------------------------------------------
select order_id, total_amount
  into temporary t_order_qty5
  from public.create_order_with_hold(
    'rfc008-org-a', 'rfc008-show',
    '[{"ticketTypeId": "08c00000-0000-0000-0000-000000000001", "quantity": 5}]'::jsonb,
    'Buyer Five', 'buyer5@example.test', null,
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
  );

-- ---------------------------------------------------------------------------
-- Order 3: two mixed order_items (2 General + 3 VIP -> 5 tickets total,
-- correctly split 2/3 across the two order_items' own sequences).
-- ---------------------------------------------------------------------------
select order_id, total_amount
  into temporary t_order_mixed
  from public.create_order_with_hold(
    'rfc008-org-a', 'rfc008-show',
    '[{"ticketTypeId": "08c00000-0000-0000-0000-000000000001", "quantity": 2}, {"ticketTypeId": "08c00000-0000-0000-0000-000000000002", "quantity": 3}]'::jsonb,
    'Buyer Mixed', 'buyermixed@example.test', null,
    'cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  );

-- ---------------------------------------------------------------------------
-- Order 4: stays PENDING_PAYMENT (never confirmed) - used for gating tests.
-- ---------------------------------------------------------------------------
select order_id
  into temporary t_order_pending
  from public.create_order_with_hold(
    'rfc008-org-a', 'rfc008-show',
    '[{"ticketTypeId": "08c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Buyer Pending', 'buyerpending@example.test', null,
    'dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd'
  );

-- ---------------------------------------------------------------------------
-- Order 5: EXPIRED - used for gating tests.
-- ---------------------------------------------------------------------------
select order_id
  into temporary t_order_expired
  from public.create_order_with_hold(
    'rfc008-org-a', 'rfc008-show',
    '[{"ticketTypeId": "08c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Buyer Expired', 'buyerexpired@example.test', null,
    'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee'
  );
update public.orders set expires_at = now() - interval '1 minute' where id = (select order_id from t_order_expired);
update public.ticket_holds set expires_at = now() - interval '1 minute' where order_id = (select order_id from t_order_expired);

-- ---------------------------------------------------------------------------
-- Order 6: PAYMENT_FAILED - used for gating tests. Recorded via a rejected
-- (non-APPROVED) confirm_order_payment call, mirroring how a real
-- provider rejection is recorded.
-- ---------------------------------------------------------------------------
select order_id
  into temporary t_order_failed
  from public.create_order_with_hold(
    'rfc008-org-a', 'rfc008-show',
    '[{"ticketTypeId": "08c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Buyer Failed', 'buyerfailed@example.test', null,
    'ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff'
  );
update public.orders set status = 'PAYMENT_FAILED' where id = (select order_id from t_order_failed);

-- =============================================================================
-- SECTION C: successful issuance via confirm_order_payment (the real path)
-- =============================================================================

select outcome
  into temporary t_confirm_qty1
  from public.confirm_order_payment(
    (select order_id from t_order_qty1), 'MERCADO_PAGO', 'mp-payment-qty1',
    'APPROVED', (select total_amount from t_order_qty1), 'ARS', 'credit_card', '{}'::jsonb,
    now(), null, :'qr_key'
  );

select is(
  (select outcome from t_confirm_qty1), 'PAID',
  '10: qty-1 order confirms to PAID'
);

select is(
  (select count(*)::int from public.tickets where order_id = (select order_id from t_order_qty1)),
  1,
  '11: exactly 1 ticket was issued for a quantity-1 order'
);

select outcome
  into temporary t_confirm_qty5
  from public.confirm_order_payment(
    (select order_id from t_order_qty5), 'MERCADO_PAGO', 'mp-payment-qty5',
    'APPROVED', (select total_amount from t_order_qty5), 'ARS', 'credit_card', '{}'::jsonb,
    now(), null, :'qr_key'
  );

select is(
  (select count(*)::int from public.tickets where order_id = (select order_id from t_order_qty5)),
  5,
  '12: exactly 5 tickets were issued for a quantity-5 order'
);

select outcome
  into temporary t_confirm_mixed
  from public.confirm_order_payment(
    (select order_id from t_order_mixed), 'MERCADO_PAGO', 'mp-payment-mixed',
    'APPROVED', (select total_amount from t_order_mixed), 'ARS', 'credit_card', '{}'::jsonb,
    now(), null, :'qr_key'
  );

select is(
  (select count(*)::int from public.tickets where order_id = (select order_id from t_order_mixed)),
  5,
  '13: exactly 5 tickets were issued for a mixed order (2 General + 3 VIP)'
);

select is(
  (select count(distinct order_item_id)::int from public.tickets where order_id = (select order_id from t_order_mixed)),
  2,
  '14: the mixed order''s tickets are correctly split across its 2 distinct order_items'
);

select is(
  (select count(*)::int from public.tickets t join public.order_items oi
     on oi.organization_id = t.organization_id and oi.id = t.order_item_id
     where t.order_id = (select order_id from t_order_mixed) and oi.ticket_type_id = '08c00000-0000-0000-0000-000000000001'),
  2,
  '15: 2 tickets carry the General ticket_type_id'
);

select is(
  (select count(*)::int from public.tickets t join public.order_items oi
     on oi.organization_id = t.organization_id and oi.id = t.order_item_id
     where t.order_id = (select order_id from t_order_mixed) and oi.ticket_type_id = '08c00000-0000-0000-0000-000000000002'),
  3,
  '16: 3 tickets carry the VIP ticket_type_id'
);

select is(
  (select status from public.tickets where order_id = (select order_id from t_order_qty1) limit 1),
  'VALID',
  '17: a freshly issued ticket has status VALID'
);

select ok(
  (select issued_at from public.tickets where order_id = (select order_id from t_order_qty1) limit 1) is not null,
  '18: a freshly issued ticket has issued_at stamped'
);

select ok(
  (select checked_in_at from public.tickets where order_id = (select order_id from t_order_qty1) limit 1) is null,
  '19: a freshly issued ticket has NOT been checked in'
);

-- No-client-trust / multi-tenancy: every issued ticket inherits its
-- organization_id/event_id/ticket_type_id from the order_item/order it
-- was derived from - never anything a caller supplied directly (issuance
-- takes no such arguments at all).
select is(
  (select count(*)::int from public.tickets t
     where t.order_id = (select order_id from t_order_qty1)
       and (t.organization_id, t.event_id) <> ('08a00000-0000-0000-0000-00000000000a', '08e00000-0000-0000-0000-000000000001')),
  0,
  '20: every issued ticket carries the correct (organization_id, event_id) derived from its order - never a mismatched tenant'
);

-- =============================================================================
-- SECTION D: idempotency - repeated/duplicate webhook delivery
-- =============================================================================

select outcome
  into temporary t_confirm_qty1_dup
  from public.confirm_order_payment(
    (select order_id from t_order_qty1), 'MERCADO_PAGO', 'mp-payment-qty1',
    'APPROVED', (select total_amount from t_order_qty1), 'ARS', 'credit_card', '{}'::jsonb,
    now(), null, :'qr_key'
  );

select is(
  (select outcome from t_confirm_qty1_dup), 'ALREADY_PROCESSED',
  '21: redelivering the same webhook notification is a safe idempotent no-op at the payment layer'
);

select is(
  (select count(*)::int from public.tickets where order_id = (select order_id from t_order_qty1)),
  1,
  '22: still exactly 1 ticket after the duplicate webhook delivery - issuance was not repeated'
);

-- Calling issuance directly, repeatedly, several times (simulating
-- multiple redelivered webhooks all reaching the issuance step) must
-- always converge to the same count - 1, 5, or 20 calls, same result.
select issue_tickets_for_order(
  (select order_id from t_order_qty5), :'qr_key'
) into temporary t_reissue_1;
select issue_tickets_for_order(
  (select order_id from t_order_qty5), :'qr_key'
) into temporary t_reissue_2;

select is(
  (select count(*)::int from public.tickets where order_id = (select order_id from t_order_qty5)),
  5,
  '23: calling issue_tickets_for_order twice more directly still yields exactly 5 tickets total (never duplicated)'
);

-- =============================================================================
-- SECTION E: payment-state gating - cannot issue for a non-paid order
-- =============================================================================

select throws_ok(
  format('select public.issue_tickets_for_order(%L::uuid, %L)', (select order_id from t_order_pending), :'qr_key'),
  'LT021', null,
  '24: issuance is rejected for a PENDING_PAYMENT order'
);

select throws_ok(
  format('select public.issue_tickets_for_order(%L::uuid, %L)', (select order_id from t_order_expired), :'qr_key'),
  'LT021', null,
  '25: issuance is rejected for an EXPIRED order'
);

select throws_ok(
  format('select public.issue_tickets_for_order(%L::uuid, %L)', (select order_id from t_order_failed), :'qr_key'),
  'LT021', null,
  '26: issuance is rejected for a PAYMENT_FAILED order'
);

select throws_ok(
  $$ select public.issue_tickets_for_order('00000000-0000-0000-0000-000000000000'::uuid, 'irrelevant') $$,
  'LT020', null,
  '27: issuance is rejected for a nonexistent order id'
);

select is_empty(
  $$ select 1 from public.tickets where order_id in (
       select id from public.orders where status in ('PENDING_PAYMENT', 'EXPIRED', 'PAYMENT_FAILED')
     ) $$,
  '28: no ticket exists anywhere for any non-paid order'
);

-- confirm_order_payment itself never lets a non-payable order reach
-- issuance either - approving a payment for the PAYMENT_FAILED order is
-- rejected at the order-state check, long before issuance would run.
select outcome
  into temporary t_confirm_failed_order
  from public.confirm_order_payment(
    (select order_id from t_order_failed), 'MERCADO_PAGO', 'mp-payment-failed-order-retry',
    'APPROVED', 100000, 'ARS', 'credit_card', '{}'::jsonb, now(), null, :'qr_key'
  );

select is(
  (select outcome from t_confirm_failed_order), 'REJECTED_ORDER_STATE',
  '29: confirm_order_payment refuses to move a PAYMENT_FAILED order to PAID at all'
);

-- =============================================================================
-- SECTION F: the isolating "_safe" wrapper never lets an issuance failure
-- undo a PAID transition
-- =============================================================================
-- Calling issue_tickets_for_order_safe with an intentionally-invalid
-- encryption key argument (empty string, which issue_tickets_for_order
-- itself raises LT020 on) must be swallowed - the function must not raise,
-- and must instead leave a diagnosable audit_logs row.

select lives_ok(
  format('select public.issue_tickets_for_order_safe(%L::uuid, %L)', (select order_id from t_order_qty1), ''),
  '30: issue_tickets_for_order_safe never raises, even when the underlying issuance call fails'
);

select is(
  (select count(*)::int from public.audit_logs
     where action = 'tickets_issuance_failed' and entity_id = (select order_id from t_order_qty1)),
  1,
  '31: the swallowed issuance failure was recorded to audit_logs for operator diagnosis'
);

select is_empty(
  $$ select 1 from public.audit_logs where action = 'tickets_issuance_failed' and metadata::text ilike '%test-only-qr-encryption-key%' $$,
  '32: the audit_logs failure entry never contains the QR encryption key or any raw secret value'
);

select is(
  (select count(*)::int from public.audit_logs
     where action = 'tickets_issued' and entity_id = (select order_id from t_order_qty1)),
  1,
  '33: a successful issuance (from Section C) was separately recorded as a distinct tickets_issued audit_logs entry'
);

-- =============================================================================
-- SECTION G: QR invariants
-- =============================================================================

select is(
  (select count(distinct qr_token_hash)::int from public.tickets),
  (select count(*)::int from public.tickets),
  '34: every issued ticket has a DISTINCT qr_token_hash (no two tickets ever share a QR secret)'
);

select is_empty(
  $$ select 1 from public.tickets where qr_token_hash is null $$,
  '35: no issued ticket has a null qr_token_hash'
);

select ok(
  (select length(qr_token_hash) from public.tickets limit 1) = 64,
  '36: qr_token_hash is a 64-hex-char sha256 digest'
);

-- Decrypting each ticket's ciphertext with the correct key and re-hashing
-- the result must reproduce the SAME hash stored alongside it - proving
-- qr_token_hash and qr_secret_ciphertext are two views of the same
-- underlying raw secret, not independently-generated values.
select is(
  (select count(*)::int from public.tickets t
     where t.qr_token_hash <> encode(digest(pgp_sym_decrypt(t.qr_secret_ciphertext, :'qr_key'), 'sha256'), 'hex')),
  0,
  '37: for every ticket, sha256(decrypt(ciphertext)) == qr_token_hash (hash and ciphertext are consistent)'
);

-- Decrypting with the WRONG key must fail loudly (pgp_sym_decrypt raises),
-- never silently return a usable value - a database leak alone (without
-- the real key) must never yield a usable raw QR secret.
select throws_ok(
  $$ select pgp_sym_decrypt(qr_secret_ciphertext, 'a-completely-wrong-key') from public.tickets limit 1 $$,
  null, null,
  '38: decrypting a QR secret with the wrong key fails - a leaked ciphertext alone is not a usable credential'
);

select is(
  (select count(distinct qr_secret_ciphertext)::int from public.tickets),
  (select count(*)::int from public.tickets),
  '39: every ticket''s ciphertext is distinct (pgp_sym_encrypt is randomized per call, never reused)'
);

-- =============================================================================
-- SECTION H: get_order_tickets - the buyer-facing read boundary
-- =============================================================================

select ok(
  (select count(*)::int from public.get_order_tickets((select order_id from t_order_qty5), :'qr_key')) = 5,
  '40: get_order_tickets returns exactly the 5 tickets belonging to the qty-5 order'
);

select ok(
  (select qr_raw_token from public.get_order_tickets((select order_id from t_order_qty1), :'qr_key') limit 1) is not null,
  '41: get_order_tickets returns a usable (decrypted) raw QR token per ticket, given the correct key'
);

select is(
  (select encode(digest((select qr_raw_token from public.get_order_tickets((select order_id from t_order_qty1), :'qr_key') limit 1), 'sha256'), 'hex')),
  (select qr_token_hash from public.tickets where order_id = (select order_id from t_order_qty1) limit 1),
  '42: the raw token get_order_tickets returns hashes to exactly the stored qr_token_hash'
);

select throws_ok(
  format('select * from public.get_order_tickets(%L::uuid, %L)', (select order_id from t_order_pending), :'qr_key'),
  'LT022', null,
  '43: get_order_tickets refuses a PENDING_PAYMENT order (never paid, no tickets to expose)'
);

select throws_ok(
  $$ select * from public.get_order_tickets('00000000-0000-0000-0000-000000000000'::uuid, 'irrelevant') $$,
  'LT022', null,
  '44: get_order_tickets refuses a nonexistent order id with the SAME error as a never-paid order (no existence leak)'
);

-- pgTAP's temporary tables (t_order_qty1, etc.) are owned by the role
-- running this script and are not readable by `anon`/`authenticated` once
-- the role is switched below - capture the plain order id into a psql
-- variable first (the id itself is not a secret; only the resulting
-- ticket data is what must never be reachable by anon).
select (select order_id from t_order_qty1)::text as qty1_order_id \gset

set local role anon;

select throws_ok(
  format('select * from public.get_order_tickets(%L::uuid, %L)', :'qty1_order_id', :'qr_key'),
  '42501', null,
  '45: anon cannot execute get_order_tickets at all - order id + even the right key is never sufficient without the trusted-server EXECUTE grant'
);

select throws_ok(
  format('select public.issue_tickets_for_order(%L::uuid, %L)', :'qty1_order_id', :'qr_key'),
  '42501', null,
  '46: anon cannot execute issue_tickets_for_order either'
);

reset role;

-- =============================================================================
-- SECTION I: tenant isolation
-- =============================================================================
-- Org B has no orders/tickets at all in this fixture set - confirms
-- get_order_tickets / the tickets table never leak Org A's tickets under
-- an Org B lookup path.

select is_empty(
  $$ select 1 from public.tickets where organization_id = '08a00000-0000-0000-0000-00000000000b' $$,
  '47: Org B has zero tickets (no cross-tenant bleed from Org A''s issuance)'
);

-- Dashboard read (RLS-mediated, unchanged from RFC-002): an Org B OWNER
-- authenticated session still cannot see Org A's tickets via a direct
-- table SELECT.
set local role authenticated;
select set_config('request.jwt.claim.sub', '08000000-0000-0000-0000-000000000002', true);

select is_empty(
  $$ select 1 from public.tickets where organization_id = '08a00000-0000-0000-0000-00000000000a' $$,
  '48: an authenticated Org B OWNER cannot see Org A''s tickets (RFC-002''s tickets_select_operator RLS policy, unchanged)'
);

reset role;

-- =============================================================================
-- SECTION J: real-Supabase corrective-fix regression coverage
-- =============================================================================
-- Added after a real `supabase test db` run against an actual local
-- Supabase stack (not the disposable substitute Postgres used during
-- development) surfaced three real bugs in this migration:
--   (1) tickets.ticket_sequence / qr_secret_ciphertext were wrongly
--       NOT NULL, breaking rfc_002_security.test.sql's own direct-insert
--       fixture (a ticket row predating RFC-008's issuance concept).
--   (2) confirm_order_payment gained a REQUIRED 11th parameter, breaking
--       every one of rfc_007_payments.test.sql's 14 historical 10-argument
--       call sites ("function ... does not exist").
--   (3) gen_random_bytes/digest/pgp_sym_encrypt are real pgcrypto
--       functions that live in Supabase's `extensions` schema, not
--       `public`, and were unreachable from this migration's
--       `set search_path = public, pg_temp` functions.
-- These assertions lock in the fixes for all three, plus the new
-- reconcile_missing_tickets recovery function added to close the
-- observability gap bug (3) exposed: issue_tickets_for_order_safe
-- correctly protects an already-PAID transition from an issuance bug, but
-- on its own left a PAID-with-zero-tickets order invisible outside of
-- audit_logs. Nothing here duplicates or weakens rfc_002-through-007
-- coverage - those files are untouched.

-- ---------------------------------------------------------------------------
-- J1 (fix 1): a legacy ticket row inserted directly, RFC-002's own
-- fixture style, predating RFC-008 entirely - NO ticket_sequence, NO
-- qr_secret_ciphertext - must still be perfectly valid.
-- ---------------------------------------------------------------------------
select lives_ok(
  format(
    $sql$
      insert into public.tickets (
        id, organization_id, event_id, order_id, order_item_id, ticket_type_id,
        ticket_number, status
      )
      select %L::uuid, oi.organization_id, o.event_id, oi.order_id, oi.id, oi.ticket_type_id,
        'RFC008-LEGACY-0001', 'VALID'
      from public.order_items oi
      join public.orders o on o.organization_id = oi.organization_id and o.id = oi.order_id
      where oi.order_id = %L::uuid
      limit 1
    $sql$,
    '08d00000-0000-0000-0000-000000000001',
    (select order_id from t_order_qty1)
  ),
  '49: a legacy ticket row with NO ticket_sequence/qr_secret_ciphertext (RFC-002''s own direct-insert fixture pattern) still inserts cleanly - RFC-008 did not retroactively break RFC-002''s data model'
);

select is(
  (select status from public.tickets where id = '08d00000-0000-0000-0000-000000000001'),
  'VALID',
  '50: that legacy ticket (ticket_sequence and qr_secret_ciphertext both null) reads back normally as a valid ticket'
);

-- ---------------------------------------------------------------------------
-- J2 (fix 1, the actual invariant): every RFC-008-issued ticket carries
-- ticket_sequence and qr_secret_ciphertext TOGETHER - never one without
-- the other. The legacy row above (both null) is excluded on purpose;
-- everything issue_tickets_for_order has ever produced must pair them.
-- ---------------------------------------------------------------------------
select is(
  (select count(*)::int from public.tickets
     where id <> '08d00000-0000-0000-0000-000000000001'
       and (ticket_sequence is null) <> (qr_secret_ciphertext is null)),
  0,
  '51: every RFC-008-issued ticket has ticket_sequence and qr_secret_ciphertext populated together - never one without the other'
);

select ok(
  (select count(*)::int from public.tickets
     where id <> '08d00000-0000-0000-0000-000000000001'
       and ticket_sequence is not null and qr_secret_ciphertext is not null) > 0,
  '52: at least one RFC-008-issued ticket genuinely has both populated (the pairing check in 51 is not vacuously true)'
);

-- ---------------------------------------------------------------------------
-- J3 (fix 2 + fix 3 + the issuance-visibility audit): a brand-new order,
-- confirmed with the EXACT historical 10-argument confirm_order_payment
-- call form - no p_qr_encryption_key at all - reproducing precisely how
-- every rfc_007_payments.test.sql assertion calls this function.
-- ---------------------------------------------------------------------------
select order_id, total_amount
  into temporary t_order_legacy_sig
  from public.create_order_with_hold(
    'rfc008-org-a', 'rfc008-show',
    '[{"ticketTypeId": "08c00000-0000-0000-0000-000000000001", "quantity": 2}]'::jsonb,
    'Buyer Legacy Sig', 'buyer-legacy-sig@example.test', null,
    'ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'
  );

select outcome
  into temporary t_confirm_legacy_sig
  from public.confirm_order_payment(
    (select order_id from t_order_legacy_sig), 'MERCADO_PAGO', 'mp-payment-legacy-sig',
    'APPROVED', (select total_amount from t_order_legacy_sig), 'ARS', 'credit_card', '{}'::jsonb,
    now(), null
  );

select is(
  (select outcome from t_confirm_legacy_sig), 'PAID',
  '53: the historical 10-argument confirm_order_payment call (no p_qr_encryption_key at all) still resolves and still transitions the order to PAID - the exact call form every rfc_007_payments.test.sql assertion uses'
);

select is(
  (select count(*)::int from public.tickets where order_id = (select order_id from t_order_legacy_sig)),
  0,
  '54: with no encryption key available (legacy call form), 0 tickets were issued for it - reproducing the exact real-world failure mode this fix round addresses'
);

select is(
  (select count(*)::int from public.audit_logs
     where action = 'tickets_issuance_failed' and entity_id = (select order_id from t_order_legacy_sig)),
  1,
  '55: the missing-key issuance failure was NOT silently invisible - it was recorded to audit_logs for operator diagnosis, exactly like any other issuance failure'
);

-- ---------------------------------------------------------------------------
-- J4: reconcile_missing_tickets - durable, idempotent detection AND
-- recovery of exactly this "PAID but tickets missing" condition (RFC-008's
-- answer to the observability gap issue_tickets_for_order_safe's own
-- exception isolation would otherwise leave open).
-- ---------------------------------------------------------------------------
select order_id, status, tickets_issued
  into temporary t_reconcile_1
  from public.reconcile_missing_tickets(:'qr_key');

select ok(
  (select count(*)::int from t_reconcile_1) = 1
    and (select order_id from t_reconcile_1 limit 1) = (select order_id from t_order_legacy_sig),
  '56: reconcile_missing_tickets finds this PAID-but-missing-tickets order entirely on its own (only the encryption key was supplied) - and finds nothing else, since every other order in this suite is already fully ticketed'
);

select is(
  (select status from t_reconcile_1 where order_id = (select order_id from t_order_legacy_sig)),
  'ISSUED',
  '57: reconcile_missing_tickets successfully recovers it once a valid key is available'
);

select is(
  (select tickets_issued from t_reconcile_1 where order_id = (select order_id from t_order_legacy_sig)),
  2,
  '58: reconcile_missing_tickets issued exactly the 2 tickets this order was always owed - no more, no fewer'
);

select is(
  (select count(*)::int from public.tickets where order_id = (select order_id from t_order_legacy_sig)),
  2,
  '59: the order''s actual ticket count now matches its order_items quantity - the recovery is real, not just reported'
);

select order_id, status, tickets_issued
  into temporary t_reconcile_2
  from public.reconcile_missing_tickets(:'qr_key');

select is(
  (select count(*)::int from t_reconcile_2 where order_id = (select order_id from t_order_legacy_sig)),
  0,
  '60: running reconcile_missing_tickets again is a safe no-op for this now-fully-ticketed order - it is never reprocessed or duplicated'
);

-- ---------------------------------------------------------------------------
-- J5: reconcile_missing_tickets is exactly as privileged as the other
-- issuance-touching functions - service_role only, never anon/authenticated.
-- ---------------------------------------------------------------------------
select ok(
  not has_function_privilege('anon', (select oid from pg_proc where proname = 'reconcile_missing_tickets' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '61: anon has NO EXECUTE privilege on reconcile_missing_tickets - recovery is an operator/service-role-only tool, never reachable from the browser'
);

select ok(
  not has_function_privilege('authenticated', (select oid from pg_proc where proname = 'reconcile_missing_tickets' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '62: authenticated has NO EXECUTE privilege on reconcile_missing_tickets either'
);

select ok(
  has_function_privilege('service_role', (select oid from pg_proc where proname = 'reconcile_missing_tickets' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '63: service_role has EXECUTE on reconcile_missing_tickets (its only intended caller)'
);

select * from finish();
rollback;
