-- RFC-007 database test suite (pgTAP): Mercado Pago Checkout Pro & Payment
-- Processing.
--
-- Exercises supabase/migrations/20260925000000_rfc_007_mercado_pago.sql:
-- record_payment_preference, confirm_order_payment, record_webhook_event,
-- mark_webhook_event, and the redefined get_checkout_order/orders schema
-- change (provider_preference_id/provider_checkout_url). Does NOT re-test
-- anything RFC-002/003/004/005/006 already cover (organizer RLS, publish
-- invariants, public event access, create_order_with_hold's own checkout
-- validation) - those are unchanged by this migration.
--
-- Auth simulation: same pattern as rfc_002_security.test.sql -
-- `set_config('request.jwt.claim.sub', ...)` + `set local role` reproduces
-- exactly what PostgREST sets per request.
--
-- A note on transaction boundaries (same reasoning as RFC-006's test file):
-- assertions that expect a function to RAISE go through pgTAP's
-- `throws_ok()`, which wraps the call in its own SAVEPOINT internally - a
-- bare failing call inside this file's own `begin ... rollback` would abort
-- the entire test transaction on the first expected failure.
--
-- True concurrent-connection testing (two overlapping transactions racing
-- confirm_order_payment's row lock) cannot be exercised inside this single
-- pgTAP transaction/connection - see scripts/rfc-007-concurrency-test.sh,
-- which proves that scenario with two real, concurrent psql connections
-- against a running local stack (documented but not executed in this
-- environment - see the final report's "Mercado Pago sandbox QA" /
-- "environment limitations" sections for why).
--
-- Run via the Supabase CLI once a local stack is available:
--   supabase test db

begin;

create extension if not exists pgtap with schema extensions;

select plan(74);

-- =============================================================================
-- SECTION A: function privileges (pure catalog state, no fixtures needed)
-- =============================================================================
-- Looked up by name (not by function_privs_are's schema+argtypes form):
-- each of these names is unique in the database (no overloads), so an oid
-- subquery on pg_proc.proname avoids any risk of mis-spelling a
-- catalog-internal type name (e.g. char(3) is stored as `bpchar`) in an
-- argument-type array - has_function_privilege(role, oid, 'EXECUTE') tests
-- the exact same real grant either way.

select ok(
  has_function_privilege('anon', (select oid from pg_proc where proname = 'record_payment_preference' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '01: anon has EXECUTE on record_payment_preference (checkout-token-authorized, same trust boundary as RFC-006''s create_order_with_hold)'
);

select ok(
  has_function_privilege('authenticated', (select oid from pg_proc where proname = 'record_payment_preference' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '02: authenticated has EXECUTE on record_payment_preference'
);

select is_empty(
  $$ select 1 from pg_proc p, lateral aclexplode(p.proacl) a
     where p.proname = 'record_payment_preference' and p.pronamespace = 'public'::regnamespace
       and a.grantee = 0 $$,
  '03: the PUBLIC pseudo-role has no ACL entry at all on record_payment_preference (explicitly revoked, not merely never granted)'
);

select ok(
  not has_function_privilege('anon', (select oid from pg_proc where proname = 'confirm_order_payment' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '04: anon has NO EXECUTE privilege on confirm_order_payment (the payment-truth boundary - RFC-007 section 53)'
);

select ok(
  not has_function_privilege('authenticated', (select oid from pg_proc where proname = 'confirm_order_payment' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '05: authenticated has NO EXECUTE privilege on confirm_order_payment'
);

select ok(
  has_function_privilege('service_role', (select oid from pg_proc where proname = 'confirm_order_payment' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '06: service_role has EXECUTE on confirm_order_payment (its only intended caller)'
);

select ok(
  not has_function_privilege('anon', (select oid from pg_proc where proname = 'record_webhook_event' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '07: anon has NO EXECUTE privilege on record_webhook_event'
);

select ok(
  not has_function_privilege('authenticated', (select oid from pg_proc where proname = 'record_webhook_event' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '08: authenticated has NO EXECUTE privilege on record_webhook_event'
);

select ok(
  has_function_privilege('service_role', (select oid from pg_proc where proname = 'record_webhook_event' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '09: service_role has EXECUTE on record_webhook_event'
);

select ok(
  not has_function_privilege('anon', (select oid from pg_proc where proname = 'mark_webhook_event' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '10: anon has NO EXECUTE privilege on mark_webhook_event'
);

select ok(
  not has_function_privilege('authenticated', (select oid from pg_proc where proname = 'mark_webhook_event' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '11: authenticated has NO EXECUTE privilege on mark_webhook_event'
);

select ok(
  has_function_privilege('service_role', (select oid from pg_proc where proname = 'mark_webhook_event' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '12: service_role has EXECUTE on mark_webhook_event'
);

select ok(
  has_function_privilege('anon', (select oid from pg_proc where proname = 'get_checkout_order' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '13: anon still has EXECUTE on the redefined get_checkout_order (DROP+CREATE preserved its grants)'
);

select ok(
  has_function_privilege('authenticated', (select oid from pg_proc where proname = 'get_checkout_order' and pronamespace = 'public'::regnamespace), 'EXECUTE'),
  '14: authenticated still has EXECUTE on the redefined get_checkout_order'
);

-- ---------------------------------------------------------------------------
-- RLS remains enabled (RFC-007 does not weaken it anywhere) - direct catalog
-- check, not inferred from behavior alone.
-- ---------------------------------------------------------------------------
select results_eq(
  $$ select relrowsecurity from pg_class where relname = 'payments' and relnamespace = 'public'::regnamespace $$,
  $$ values (true) $$,
  '15: RLS remains enabled on payments'
);

select results_eq(
  $$ select relrowsecurity from pg_class where relname = 'webhook_events' and relnamespace = 'public'::regnamespace $$,
  $$ values (true) $$,
  '16: RLS remains enabled on webhook_events'
);

select results_eq(
  $$ select relrowsecurity from pg_class where relname = 'orders' and relnamespace = 'public'::regnamespace $$,
  $$ values (true) $$,
  '17: RLS remains enabled on orders'
);

-- =============================================================================
-- SECTION B: fixtures
-- =============================================================================

insert into auth.users (id, email) values
  ('07000000-0000-0000-0000-000000000001', 'owner-a@example.test'),
  ('07000000-0000-0000-0000-000000000002', 'owner-b@example.test');

insert into public.organizations (id, name, slug, currency, timezone) values
  ('07a00000-0000-0000-0000-00000000000a', 'RFC-007 Org A', 'rfc007-org-a', 'ARS', 'America/Argentina/Buenos_Aires'),
  ('07a00000-0000-0000-0000-00000000000b', 'RFC-007 Org B', 'rfc007-org-b', 'ARS', 'America/Argentina/Buenos_Aires');

insert into public.organization_members (organization_id, user_id, role) values
  ('07a00000-0000-0000-0000-00000000000a', '07000000-0000-0000-0000-000000000001', 'OWNER'),
  ('07a00000-0000-0000-0000-00000000000b', '07000000-0000-0000-0000-000000000002', 'OWNER');

insert into public.events (id, organization_id, name, slug, starts_at, venue_name, status) values
  ('07e00000-0000-0000-0000-000000000001', '07a00000-0000-0000-0000-00000000000a', 'RFC-007 Show', 'rfc007-show', now() + interval '30 days', 'Teatro Colon', 'DRAFT'),
  ('07e00000-0000-0000-0000-00000000000b', '07a00000-0000-0000-0000-00000000000b', 'RFC-007 Org B Show', 'rfc007-org-b-show', now() + interval '30 days', 'Estadio B', 'DRAFT');

insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  -- Plenty of capacity - used for the happy path, mismatch, retry, and
  -- external-reference tests, where inventory scarcity is not the point.
  ('07c00000-0000-0000-0000-000000000001', '07a00000-0000-0000-0000-00000000000a', '07e00000-0000-0000-0000-000000000001', 'General', 100000, 'ARS', 20, 'PUBLIC', true),
  -- Exactly 2 units - used for the "no double-counting" inventory
  -- transition test.
  ('07c00000-0000-0000-0000-000000000002', '07a00000-0000-0000-0000-00000000000a', '07e00000-0000-0000-0000-000000000001', 'Limited', 50000, 'ARS', 2, 'PUBLIC', true),
  -- Exactly 1 unit - used for the payment-vs-expiration race tests
  -- (late-recovery success and late-recovery oversell rejection).
  ('07c00000-0000-0000-0000-000000000003', '07a00000-0000-0000-0000-00000000000a', '07e00000-0000-0000-0000-000000000001', 'Solo', 30000, 'ARS', 1, 'PUBLIC', true);

update public.events set status = 'PUBLISHED' where id = '07e00000-0000-0000-0000-000000000001';

-- ---------------------------------------------------------------------------
-- anon/authenticated: no direct table access to payments/webhook_events
-- (RFC-002's RLS, untouched by RFC-007) - access is entirely mediated
-- through record_payment_preference/confirm_order_payment/etc.
-- ---------------------------------------------------------------------------
set local role anon;

select is_empty(
  $$ select 1 from public.payments $$,
  '18: anon cannot directly SELECT any row from payments'
);

select is_empty(
  $$ select 1 from public.webhook_events $$,
  '19: anon cannot directly SELECT any row from webhook_events'
);

select throws_ok(
  $$ insert into public.webhook_events (provider, provider_event_id, event_type, payload)
     values ('MERCADO_PAGO', 'forged-event-1', 'payment', '{}'::jsonb) $$,
  '42501', null,
  '20: anon cannot directly INSERT into webhook_events'
);

select throws_ok(
  $$ insert into public.payments (organization_id, order_id, provider, provider_payment_id, status, paid_amount, currency)
     values ('07a00000-0000-0000-0000-00000000000a', '07a00000-0000-0000-0000-00000000000a', 'MERCADO_PAGO', 'forged-payment-1', 'APPROVED', 0, 'ARS') $$,
  '42501', null,
  '21: anon cannot directly INSERT into payments'
);

reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);

select is_empty(
  $$ select 1 from public.webhook_events $$,
  '22: an authenticated caller with no resolvable auth.uid() cannot SELECT webhook_events either'
);

reset role;

-- confirm_order_payment cannot be executed by anon/authenticated at all -
-- Postgres refuses to even attempt the call (permission denied for
-- function), independent of any argument values.
set local role anon;

select throws_ok(
  $$ select * from public.confirm_order_payment(
       '07a00000-0000-0000-0000-00000000000a'::uuid, 'MERCADO_PAGO'::public.payment_provider,
       'irrelevant', 'APPROVED'::public.payment_status, 0::bigint, 'ARS'::char(3),
       null, '{}'::jsonb, null, null
     ) $$,
  '42501', null,
  '23: anon cannot execute confirm_order_payment at all (no EXECUTE grant - RFC-007 section 53)'
);

reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '07000000-0000-0000-0000-000000000001', true);

select throws_ok(
  $$ select * from public.confirm_order_payment(
       '07a00000-0000-0000-0000-00000000000a'::uuid, 'MERCADO_PAGO'::public.payment_provider,
       'irrelevant', 'APPROVED'::public.payment_status, 0::bigint, 'ARS'::char(3),
       null, '{}'::jsonb, null, null
     ) $$,
  '42501', null,
  '24: authenticated (even an org OWNER) cannot execute confirm_order_payment either'
);

reset role;

-- =============================================================================
-- SECTION C: record_payment_preference
-- =============================================================================

-- Happy-path order used across section C/D.
select order_id, order_status, expires_at
  into temporary t_pref_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000001", "quantity": 2}]'::jsonb,
    'Preference Buyer', 'preference.buyer@example.test', null,
    '1111111111111111111111111111111111111111111111111111111111111111'
  );

select order_id, provider_preference_id, provider_checkout_url
  into temporary t_pref_result
  from public.record_payment_preference(
    (select order_id from t_pref_order),
    '1111111111111111111111111111111111111111111111111111111111111111',
    'MERCADO_PAGO', 'mp-pref-001', 'https://sandbox.mercadopago.com.ar/checkout/v1/redirect?pref_id=mp-pref-001'
  );

select ok(
  (select provider_preference_id from t_pref_result) = 'mp-pref-001',
  '25: record_payment_preference persists the provider preference id'
);

select is(
  (select provider_preference_id from public.orders where id = (select order_id from t_pref_order)),
  'mp-pref-001',
  '26: the preference id is visible on the orders row afterwards'
);

select throws_ok(
  format(
    $$ select * from public.record_payment_preference(%L::uuid, %L, 'MERCADO_PAGO', 'mp-pref-wrong-token', 'https://example.test') $$,
    (select order_id from t_pref_order), 'wrong-token-hash-0000000000000000000000000000000000000000000000000'
  ),
  'LT008', null,
  '27: record_payment_preference rejects a checkout id/token mismatch (re-verifies the token itself, never trusts the caller)'
);

-- Expired-order preference rejection (RFC-007 section 35/36): simulate an
-- order the buyer let sit past its hold window (still status
-- PENDING_PAYMENT - expire_pending_orders() has not swept it yet).
select order_id
  into temporary t_expired_pref_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Expired Buyer', 'expired.buyer@example.test', null,
    '2222222222222222222222222222222222222222222222222222222222222222'
  );

update public.orders
  set expires_at = now() - interval '1 minute'
  where id = (select order_id from t_expired_pref_order);
update public.ticket_holds
  set expires_at = now() - interval '1 minute'
  where order_id = (select order_id from t_expired_pref_order);

select throws_ok(
  format(
    $$ select * from public.record_payment_preference(%L::uuid, '2222222222222222222222222222222222222222222222222222222222222222', 'MERCADO_PAGO', 'mp-pref-expired', 'https://example.test') $$,
    (select order_id from t_expired_pref_order)
  ),
  'LT011', null,
  '28: record_payment_preference refuses to create/persist a preference for an order past its expiry (never mints a new preference for an expired order - RFC-007 section 35)'
);

-- =============================================================================
-- SECTION D: confirm_order_payment - happy path
-- =============================================================================

select outcome, order_id, order_status, payment_id
  into temporary t_happy_confirm
  from public.confirm_order_payment(
    (select order_id from t_pref_order), 'MERCADO_PAGO', 'mp-payment-happy-001',
    'APPROVED', 200000, 'ARS', 'credit_card', '{"status": "approved"}'::jsonb,
    now(), null
  );

select is(
  (select outcome from t_happy_confirm), 'PAID',
  '29: confirm_order_payment with matching amount/currency/status transitions the order to PAID'
);

select is(
  (select status::text from public.orders where id = (select order_id from t_pref_order)),
  'PAID',
  '30: the order row itself is now PAID'
);

select ok(
  (select paid_at from public.orders where id = (select order_id from t_pref_order)) is not null,
  '31: paid_at was stamped'
);

select is(
  (select count(*)::int from public.payments
    where order_id = (select order_id from t_pref_order)
      and provider_payment_id = 'mp-payment-happy-001'),
  1,
  '32: exactly one payments row was created for this provider_payment_id'
);

select is(
  (select paid_amount from public.payments where provider_payment_id = 'mp-payment-happy-001'),
  200000::bigint,
  '33: the persisted payment amount matches what was verified (never client/browser-supplied)'
);

-- Duplicate webhook delivery (RFC-007 sections 28/30/66): the exact same
-- notification, redelivered.
select outcome, payment_id
  into temporary t_duplicate_confirm
  from public.confirm_order_payment(
    (select order_id from t_pref_order), 'MERCADO_PAGO', 'mp-payment-happy-001',
    'APPROVED', 200000, 'ARS', 'credit_card', '{"status": "approved"}'::jsonb,
    now(), null
  );

select is(
  (select outcome from t_duplicate_confirm), 'ALREADY_PROCESSED',
  '34: redelivering the same webhook notification is a safe idempotent no-op'
);

select is(
  (select payment_id from t_duplicate_confirm),
  (select payment_id from t_happy_confirm),
  '35: the duplicate resolves to the SAME payment_id, not a new one'
);

select is(
  (select count(*)::int from public.payments where provider_payment_id = 'mp-payment-happy-001'),
  1,
  '36: still exactly one payments row after the duplicate delivery - no double-processing'
);

-- Concurrent-duplicate backstop (RFC-007 section 67): the DB-level unique
-- constraint confirm_order_payment's exception handler relies on actually
-- exists and rejects a raw duplicate insert. True overlapping-transaction
-- concurrency is proven separately by scripts/rfc-007-concurrency-test.sh
-- (a single pgTAP transaction cannot simulate two real concurrent backends
-- racing the same row lock).
select throws_ok(
  $$ insert into public.payments (organization_id, order_id, provider, provider_payment_id, status, paid_amount, currency)
     select organization_id, id, 'MERCADO_PAGO', 'mp-payment-happy-001', 'APPROVED', 200000, 'ARS'
     from public.orders where id = (select order_id from t_pref_order) $$,
  '23505', null,
  '37: the payments(provider, provider_payment_id) unique constraint rejects a duplicate insert at the database level - the backstop confirm_order_payment''s idempotency depends on'
);

-- A second, DIFFERENT approved payment for an order already PAID.
select outcome
  into temporary t_double_paid_confirm
  from public.confirm_order_payment(
    (select order_id from t_pref_order), 'MERCADO_PAGO', 'mp-payment-second-attempt',
    'APPROVED', 200000, 'ARS', 'credit_card', '{}'::jsonb, now(), null
  );

select is(
  (select outcome from t_double_paid_confirm), 'ORDER_ALREADY_PAID',
  '38: a second distinct approved payment for an already-PAID order is recorded but never re-transitions or double-commits inventory'
);

select is(
  (select count(*)::int from public.audit_logs where action = 'payment_approved_order_already_paid'),
  1,
  '39: the already-PAID collision is recorded to audit_logs for observability'
);

-- external_reference / order-not-found (RFC-007's correlation mechanism -
-- a payment whose external_reference does not map to any real order).
select throws_ok(
  $$ select * from public.confirm_order_payment(
       '00000000-0000-0000-0000-000000000000'::uuid, 'MERCADO_PAGO', 'mp-payment-no-such-order',
       'APPROVED', 100000, 'ARS', null, '{}'::jsonb, now(), null
     ) $$,
  'LT010', null,
  '40: confirm_order_payment raises a stable domain error when external_reference does not correlate to any order'
);

select is_empty(
  $$ select 1 from public.payments where provider_payment_id = 'mp-payment-no-such-order' $$,
  '41: no payment row was created for the uncorrelated external_reference'
);

-- =============================================================================
-- SECTION E: currency / amount mismatch (RFC-007 sections 24/25)
-- =============================================================================

select order_id
  into temporary t_currency_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Currency Buyer', 'currency.buyer@example.test', null,
    '3333333333333333333333333333333333333333333333333333333333333333'
  );

select outcome
  into temporary t_currency_confirm
  from public.confirm_order_payment(
    (select order_id from t_currency_order), 'MERCADO_PAGO', 'mp-payment-currency-mismatch',
    'APPROVED', 100000, 'USD', 'credit_card', '{}'::jsonb, now(), null
  );

select is(
  (select outcome from t_currency_confirm), 'REJECTED_CURRENCY_MISMATCH',
  '42: a payment whose currency does not match the order''s currency is rejected, never marked PAID'
);

select is(
  (select status::text from public.orders where id = (select order_id from t_currency_order)),
  'PENDING_PAYMENT',
  '43: the order stays PENDING_PAYMENT after a currency-mismatch rejection (still retryable)'
);

select order_id
  into temporary t_amount_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Amount Buyer', 'amount.buyer@example.test', null,
    '4444444444444444444444444444444444444444444444444444444444444444'
  );

select outcome
  into temporary t_amount_confirm
  from public.confirm_order_payment(
    (select order_id from t_amount_order), 'MERCADO_PAGO', 'mp-payment-amount-mismatch',
    'APPROVED', 50000, 'ARS', 'credit_card', '{}'::jsonb, now(), null
  );

select is(
  (select outcome from t_amount_confirm), 'REJECTED_AMOUNT_MISMATCH',
  '44: a payment whose amount does not match the order''s authoritative total is rejected, never marked PAID'
);

select is(
  (select status::text from public.orders where id = (select order_id from t_amount_order)),
  'PENDING_PAYMENT',
  '45: the order stays PENDING_PAYMENT after an amount-mismatch rejection (still retryable)'
);

-- Retry with a NEW provider_payment_id (a genuinely new payment attempt,
-- matching Mercado Pago's own semantics - a corrected retry under the SAME
-- payment id is not a real-world case) and the correct amount succeeds.
select outcome
  into temporary t_amount_retry_confirm
  from public.confirm_order_payment(
    (select order_id from t_amount_order), 'MERCADO_PAGO', 'mp-payment-amount-corrected',
    'APPROVED', 100000, 'ARS', 'credit_card', '{}'::jsonb, now(), null
  );

select is(
  (select outcome from t_amount_retry_confirm), 'PAID',
  '46: a subsequent, correctly-amounted payment attempt for the same still-valid order succeeds'
);

-- =============================================================================
-- SECTION F: rejected-payment-attempt-retryable (RFC-007 sections 39/40/69)
-- =============================================================================

select order_id
  into temporary t_retry_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Retry Buyer', 'retry.buyer@example.test', null,
    '5555555555555555555555555555555555555555555555555555555555555555'
  );

select outcome
  into temporary t_rejected_confirm
  from public.confirm_order_payment(
    (select order_id from t_retry_order), 'MERCADO_PAGO', 'mp-payment-rejected-attempt',
    'REJECTED', 100000, 'ARS', 'credit_card', '{"status": "rejected"}'::jsonb, null, null
  );

select is(
  (select outcome from t_rejected_confirm), 'RECORDED_NOT_APPROVED',
  '47: a rejected/pending payment attempt is recorded but never transitions the order'
);

select is(
  (select status::text from public.orders where id = (select order_id from t_retry_order)),
  'PENDING_PAYMENT',
  '48: the order remains PENDING_PAYMENT (and therefore retryable) after a rejected attempt - a single rejection does not permanently fail the order'
);

select is(
  (select count(*)::int from public.ticket_holds where order_id = (select order_id from t_retry_order) and expires_at > now()),
  1,
  '49: the ticket_holds row is still active after the rejected attempt - the buyer can genuinely still retry'
);

select outcome
  into temporary t_retry_success_confirm
  from public.confirm_order_payment(
    (select order_id from t_retry_order), 'MERCADO_PAGO', 'mp-payment-retry-success',
    'APPROVED', 100000, 'ARS', 'credit_card', '{"status": "approved"}'::jsonb, now(), null
  );

select is(
  (select outcome from t_retry_success_confirm), 'PAID',
  '50: retrying with a new payment attempt after a rejection succeeds normally'
);

-- =============================================================================
-- SECTION G: inventory - no double-counting (RFC-007 section 34)
-- =============================================================================
-- Ticket type "Limited" has exactly 2 units. Order L1 takes 1, order L2
-- takes the other 1 (both still PENDING_PAYMENT: capacity now fully held).
-- Confirming L1 as PAID must not free capacity it shouldn't, and must not
-- double-count it either - available afterwards must be exactly 0, not -1
-- (double-counted: hold AND order_item both counted) and not 1 (hold
-- incorrectly still counted after payment).

select order_id
  into temporary t_l1_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000002", "quantity": 1}]'::jsonb,
    'Limited Buyer One', 'limited.one@example.test', null,
    '6666666666666666666666666666666666666666666666666666666666666666'
  );

select order_id
  into temporary t_l2_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000002", "quantity": 1}]'::jsonb,
    'Limited Buyer Two', 'limited.two@example.test', null,
    '7777777777777777777777777777777777777777777777777777777777777777'
  );

-- get_public_ticket_availability (RFC-006) only returns a boolean
-- is_sold_out signal, not a raw count - the exact same formula is
-- reproduced directly here (mirroring that function's own SQL, which its
-- own comment requires stay in sync) to assert the actual remaining
-- quantity, which is what actually proves/disproves double-counting.
create function pg_temp.rfc007_test_available(p_ticket_type_id uuid)
returns bigint
language sql
as $$
  select
    tt.quantity::bigint
    - coalesce((
        select sum(oi.quantity)
        from public.order_items oi
        join public.orders o
          on o.organization_id = oi.organization_id and o.id = oi.order_id
        where oi.ticket_type_id = tt.id and o.status = 'PAID'
      ), 0)
    - coalesce((
        select sum(h.quantity)
        from public.ticket_holds h
        join public.orders o
          on o.organization_id = h.organization_id and o.id = h.order_id
        where h.ticket_type_id = tt.id
          and o.status = 'PENDING_PAYMENT'
          and h.expires_at > now()
      ), 0)
  from public.ticket_types tt
  where tt.id = p_ticket_type_id;
$$;

select is(
  pg_temp.rfc007_test_available('07c00000-0000-0000-0000-000000000002'), 0::bigint,
  '51: with both units held by pending orders, availability is already 0 before either is paid'
);

select outcome
  into temporary t_l1_confirm
  from public.confirm_order_payment(
    (select order_id from t_l1_order), 'MERCADO_PAGO', 'mp-payment-limited-l1',
    'APPROVED', 50000, 'ARS', 'credit_card', '{}'::jsonb, now(), null
  );

select is((select outcome from t_l1_confirm), 'PAID', '52: L1''s payment confirms normally');

select is(
  pg_temp.rfc007_test_available('07c00000-0000-0000-0000-000000000002'), 0::bigint,
  '53: availability is STILL exactly 0 after L1 is paid - not -1 (would mean double-counting: hold AND payment both counted) and not 1 (would mean the hold was wrongly still counted post-payment)'
);

select is(
  (select count(*)::int from public.order_items where order_id = (select order_id from t_l1_order)),
  1,
  '54: L1''s order_item exists (the committed side of the ledger)'
);

select ok(
  (select count(*)::int from public.ticket_holds where order_id = (select order_id from t_l1_order)) = 1,
  '55: L1''s ticket_holds row is still physically present (never deleted) but is excluded from availability once its order is PAID, not PENDING_PAYMENT'
);

-- =============================================================================
-- SECTION H: payment-vs-expiration race (RFC-007 section 33)
-- =============================================================================

-- H1: late-recovery SUCCESS. The order's hold window elapsed (simulating
-- expire_pending_orders() not having run yet), but capacity is still
-- free - a genuinely approved late payment must still be honored.
select order_id
  into temporary t_late_ok_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
    'Late Recovery OK Buyer', 'late.ok@example.test', null,
    '8888888888888888888888888888888888888888888888888888888888888888'
  );

update public.orders set expires_at = now() - interval '5 minutes'
  where id = (select order_id from t_late_ok_order);
update public.ticket_holds set expires_at = now() - interval '5 minutes'
  where order_id = (select order_id from t_late_ok_order);

select outcome
  into temporary t_late_ok_confirm
  from public.confirm_order_payment(
    (select order_id from t_late_ok_order), 'MERCADO_PAGO', 'mp-payment-late-ok',
    'APPROVED', 100000, 'ARS', 'credit_card', '{}'::jsonb, now(), null
  );

select is(
  (select outcome from t_late_ok_confirm), 'PAID_LATE_RECOVERY',
  '56: a genuinely approved payment arriving after the hold window elapsed is still honored when capacity remains available'
);

select is(
  (select status::text from public.orders where id = (select order_id from t_late_ok_order)),
  'PAID',
  '57: the late-recovered order is PAID'
);

-- H2: late-recovery REJECTION (oversell prevention). "Solo" has exactly 1
-- unit. Order S1 holds it, then its window elapses; before S1's late
-- payment arrives, a completely different order S2 legitimately claims the
-- now-freed unit (create_order_with_hold's own formula already excludes
-- S1's expired hold). S1's late payment must then be rejected - "do not
-- oversell" wins over "the payment arrived late".
select order_id
  into temporary t_solo_s1_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000003", "quantity": 1}]'::jsonb,
    'Solo Buyer One', 'solo.one@example.test', null,
    '9999999999999999999999999999999999999999999999999999999999999999'
  );

update public.orders set expires_at = now() - interval '5 minutes'
  where id = (select order_id from t_solo_s1_order);
update public.ticket_holds set expires_at = now() - interval '5 minutes'
  where order_id = (select order_id from t_solo_s1_order);

select order_id
  into temporary t_solo_s2_order
  from public.create_order_with_hold(
    'rfc007-org-a', 'rfc007-show',
    '[{"ticketTypeId": "07c00000-0000-0000-0000-000000000003", "quantity": 1}]'::jsonb,
    'Solo Buyer Two', 'solo.two@example.test', null,
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
  );

select ok(
  (select order_id from t_solo_s2_order) is not null,
  '58: S2 successfully claims the Solo unit S1''s expired hold no longer reserves'
);

select outcome
  into temporary t_solo_s1_confirm
  from public.confirm_order_payment(
    (select order_id from t_solo_s1_order), 'MERCADO_PAGO', 'mp-payment-late-oversell',
    'APPROVED', 30000, 'ARS', 'credit_card', '{}'::jsonb, now(), null
  );

select is(
  (select outcome from t_solo_s1_confirm), 'REJECTED_INVENTORY_UNAVAILABLE',
  '59: S1''s late-but-genuine payment is rejected once its capacity was legitimately reclaimed by another order - never oversold'
);

-- The raw orders.status column is untouched by a rejection (only the PAID/
-- PAID_LATE_RECOVERY/ORDER_ALREADY_PAID paths ever write to it) - it still
-- literally reads PENDING_PAYMENT. What the buyer/checkout page actually
-- sees is get_checkout_order's virtual EXPIRED derivation, so that is what
-- this assertion checks, via the same checkout token S1 was created with.
select order_status
  into temporary t_solo_s1_checkout_view
  from public.get_checkout_order(
    (select order_id from t_solo_s1_order),
    '9999999999999999999999999999999999999999999999999999999999999999'
  );

select is(
  (select order_status from t_solo_s1_checkout_view),
  'EXPIRED',
  '60: S1 is reported EXPIRED via get_checkout_order''s virtual-EXPIRED derivation, never silently marked PAID'
);

select is(
  (select count(*)::int from public.payments where provider_payment_id = 'mp-payment-late-oversell'),
  1,
  '61: S1''s late payment is still recorded (full audit trail) even though the order was not transitioned - available for manual reconciliation'
);

select is(
  (select count(*)::int from public.audit_logs where action = 'payment_approved_inventory_unavailable'),
  1,
  '62: the oversell-prevention rejection is recorded to audit_logs'
);

-- =============================================================================
-- SECTION I: record_webhook_event / mark_webhook_event idempotency
-- =============================================================================

select webhook_event_id, already_existed, status
  into temporary t_webhook_first
  from public.record_webhook_event(
    'MERCADO_PAGO', 'mp-webhook-evt-001', 'payment',
    '{"id": "mp-webhook-evt-001", "type": "payment"}'::jsonb
  );

select is(
  (select already_existed from t_webhook_first), false,
  '63: the first delivery of a webhook event id is recorded as new'
);

select is(
  (select status::text from t_webhook_first), 'RECEIVED',
  '64: a freshly recorded webhook event starts as RECEIVED'
);

select webhook_event_id, already_existed
  into temporary t_webhook_duplicate
  from public.record_webhook_event(
    'MERCADO_PAGO', 'mp-webhook-evt-001', 'payment',
    '{"id": "mp-webhook-evt-001", "type": "payment"}'::jsonb
  );

select is(
  (select already_existed from t_webhook_duplicate), true,
  '65: redelivering the same provider_event_id is recognized as already-seen, not inserted twice'
);

select is(
  (select webhook_event_id from t_webhook_duplicate),
  (select webhook_event_id from t_webhook_first),
  '66: the duplicate delivery resolves to the SAME webhook_events row'
);

select is(
  (select count(*)::int from public.webhook_events where provider_event_id = 'mp-webhook-evt-001'),
  1,
  '67: exactly one webhook_events row exists for this provider_event_id, regardless of redelivery'
);

select mark_webhook_event(
  (select webhook_event_id from t_webhook_first), 'PROCESSED', null
);

select is(
  (select status::text from public.webhook_events where id = (select webhook_event_id from t_webhook_first)),
  'PROCESSED',
  '68: mark_webhook_event updates the row''s terminal status'
);

select throws_ok(
  $$ insert into public.webhook_events (provider, provider_event_id, event_type, payload)
     values ('MERCADO_PAGO', 'mp-webhook-evt-001', 'payment', '{}'::jsonb) $$,
  '23505', null,
  '69: the webhook_events(provider, provider_event_id) unique constraint independently backstops idempotency at the database level'
);

-- =============================================================================
-- SECTION J: browser-cannot-mark-PAID (RFC-007's central invariant)
-- =============================================================================
-- orders has no client-facing UPDATE policy at all (RFC-002, unchanged by
-- RFC-006/RFC-007) - Postgres RLS filters UPDATE candidate rows via USING
-- silently (0 rows affected), it does not need to throw the way INSERT's
-- WITH CHECK does; the DO block below tolerates either behavior so this
-- assertion is robust regardless of which one occurs.

-- (still PENDING_PAYMENT - the currency-mismatch order from Section E was
-- never transitioned)
--
-- The order id is stashed in a session-level custom GUC (not read from the
-- temp table directly while role-impersonating below) because temp tables
-- created earlier in this script are owned by the test-runner's own role -
-- anon/authenticated have no SELECT privilege on them, and a bare
-- role-switched reference would fail with "permission denied" for the
-- WRONG reason (a test-harness artifact, not the RLS behavior actually
-- being exercised). set_config/current_setting are plain session state,
-- readable under any role - same technique this file already uses for
-- request.jwt.claim.sub.
select set_config('rfc007_test.browser_order_id', (select order_id from t_currency_order)::text, false);

set local role anon;
do $$
begin
  update public.orders set status = 'PAID', paid_at = now()
  where id = current_setting('rfc007_test.browser_order_id')::uuid;
exception when insufficient_privilege then
  null;
end $$;
reset role;

select is(
  (select status::text from public.orders where id = current_setting('rfc007_test.browser_order_id')::uuid),
  'PENDING_PAYMENT',
  '70: anon cannot mark an order PAID via a direct UPDATE - the ONLY path to PAID is confirm_order_payment'
);

set local role authenticated;
select set_config('request.jwt.claim.sub', '07000000-0000-0000-0000-000000000001', true);
do $$
begin
  update public.orders set status = 'PAID', paid_at = now()
  where id = current_setting('rfc007_test.browser_order_id')::uuid;
exception when insufficient_privilege then
  null;
end $$;
reset role;

select is(
  (select status::text from public.orders where id = current_setting('rfc007_test.browser_order_id')::uuid),
  'PENDING_PAYMENT',
  '71: authenticated (even the owning organization''s OWNER) cannot mark an order PAID via a direct UPDATE either'
);

-- Same fake-success-URL principle at the database level: visiting/querying
-- the result page must never itself cause a transition. get_checkout_order
-- is read-only (a `select`, no writes) - assert its own definition
-- performs no INSERT/UPDATE/DELETE, so calling it can never be the thing
-- that marks an order PAID.
select is(
  (select prokind::text from pg_proc where proname = 'get_checkout_order' and pronamespace = 'public'::regnamespace),
  'f',
  '72: get_checkout_order is an ordinary read-only function (not a procedure with side effects) - visiting the result page can never itself transition an order'
);

-- =============================================================================
-- SECTION K: cross-org isolation on payments (RFC-002's RLS, reused unchanged)
-- =============================================================================
-- Same session-GUC technique as Section J, for the same reason: t_happy_confirm
-- is a temp table owned by the test-runner role, not readable while
-- impersonating authenticated below.
select set_config('rfc007_test.happy_payment_id', (select payment_id from t_happy_confirm)::text, false);

set local role authenticated;
select set_config('request.jwt.claim.sub', '07000000-0000-0000-0000-000000000001', true);

select isnt_empty(
  $$ select 1 from public.payments where id = current_setting('rfc007_test.happy_payment_id')::uuid $$,
  '73: Org A''s OWNER can see Org A''s own payment'
);

reset role;

set local role authenticated;
select set_config('request.jwt.claim.sub', '07000000-0000-0000-0000-000000000002', true);

select is_empty(
  $$ select 1 from public.payments where id = current_setting('rfc007_test.happy_payment_id')::uuid $$,
  '74: Org B''s OWNER cannot see Org A''s payment - cross-organization isolation holds for payments exactly as it does for every other RFC-002 commerce table'
);

reset role;

select * from finish();
rollback;
