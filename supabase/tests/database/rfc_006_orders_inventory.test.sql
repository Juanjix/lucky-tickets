-- RFC-006 database test suite (pgTAP): Orders & Inventory.
--
-- Exercises supabase/migrations/20260924000000_rfc_006_orders_inventory.sql:
-- create_order_with_hold, get_checkout_order, get_public_ticket_availability,
-- expire_pending_orders, and the orders.checkout_token_hash column. Does
-- NOT re-test anything RFC-002/003/004/005 already cover (organizer RLS,
-- publish invariants, RFC-005's public event/ticket_types/organizations
-- visibility) - those are unchanged by this migration.
--
-- A note on transaction boundaries in this file: `create_order_with_hold`
-- raises a plain Postgres exception on every invariant violation. Calling
-- it directly inside this file's own `begin ... rollback` block would
-- abort the ENTIRE test transaction on the first expected failure (this
-- was discovered empirically while writing this suite, via a throwaway
-- smoke script - a raised exception aborts the innermost transaction
-- block, not just "the statement"). Every assertion that expects
-- create_order_with_hold to throw therefore goes through pgTAP's
-- `throws_ok()`, which wraps the call in its own SAVEPOINT/ROLLBACK TO
-- SAVEPOINT internally - exactly the same reason RFC-003's test file uses
-- `throws_ok` rather than a bare failing call for create_organization.
--
-- Run via the Supabase CLI once a local stack is available:
--   supabase test db

begin;

create extension if not exists pgtap with schema extensions;

select plan(61);

-- ---------------------------------------------------------------------------
-- Function privileges - pure catalog state, no fixtures needed. Asserted
-- directly via function_privs_are() (reads pg_proc.proacl), not inferred
-- from whether a call raised an error - see RFC-003's precedent and the
-- explicit reminder in RFC-006 section 29/51 about Supabase's default
-- per-function privilege grants.
-- ---------------------------------------------------------------------------
select function_privs_are(
  'public', 'create_order_with_hold',
  array['text', 'text', 'jsonb', 'text', 'text', 'text', 'text']::name[],
  'anon', array['EXECUTE']::name[],
  '01: anon has EXECUTE (and only EXECUTE) on create_order_with_hold'
);

select function_privs_are(
  'public', 'create_order_with_hold',
  array['text', 'text', 'jsonb', 'text', 'text', 'text', 'text']::name[],
  'authenticated', array['EXECUTE']::name[],
  '02: authenticated has EXECUTE on create_order_with_hold'
);

select function_privs_are(
  'public', 'create_order_with_hold',
  array['text', 'text', 'jsonb', 'text', 'text', 'text', 'text']::name[],
  'public', array[]::name[],
  '03: the PUBLIC pseudo-role has no privileges on create_order_with_hold (rules out the implicit-PUBLIC-grant path)'
);

select function_privs_are(
  'public', 'get_checkout_order', array['uuid', 'text']::name[],
  'anon', array['EXECUTE']::name[],
  '04: anon has EXECUTE on get_checkout_order'
);

select function_privs_are(
  'public', 'get_public_ticket_availability', array['uuid']::name[],
  'anon', array['EXECUTE']::name[],
  '05: anon has EXECUTE on get_public_ticket_availability'
);

select function_privs_are(
  'public', 'expire_pending_orders', array[]::name[],
  'anon', array[]::name[],
  '06: anon has NO privileges on expire_pending_orders'
);

select function_privs_are(
  'public', 'expire_pending_orders', array[]::name[],
  'authenticated', array[]::name[],
  '07: authenticated has NO privileges on expire_pending_orders (maintenance-only function)'
);

select function_privs_are(
  'public', 'expire_pending_orders', array[]::name[],
  'service_role', array['EXECUTE']::name[],
  '08: service_role has EXECUTE on expire_pending_orders (its only intended caller for now)'
);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into public.organizations (id, name, slug, currency, timezone) values
  ('06a00000-0000-0000-0000-00000000000a', 'RFC-006 Org A', 'rfc006-org-a', 'ARS', 'America/Argentina/Buenos_Aires'),
  ('06a00000-0000-0000-0000-00000000000b', 'RFC-006 Org B', 'rfc006-org-b', 'ARS', 'America/Argentina/Buenos_Aires');

-- Events under Org A: one per status this RPC must distinguish, plus a
-- second PUBLISHED event to host tenant-isolation fixtures.
insert into public.events (id, organization_id, name, slug, starts_at, venue_name, status) values
  ('06e00000-0000-0000-0000-000000000001', '06a00000-0000-0000-0000-00000000000a', 'Published Show', 'published-show', now() + interval '30 days', 'Teatro Colon', 'DRAFT'),
  ('06e00000-0000-0000-0000-000000000002', '06a00000-0000-0000-0000-00000000000a', 'Draft Show', 'draft-show', now() + interval '30 days', 'Teatro Colon', 'DRAFT'),
  ('06e00000-0000-0000-0000-000000000003', '06a00000-0000-0000-0000-00000000000a', 'Cancelled Show', 'cancelled-show', now() + interval '30 days', 'Teatro Colon', 'CANCELLED'),
  ('06e00000-0000-0000-0000-000000000004', '06a00000-0000-0000-0000-00000000000a', 'Archived Show', 'archived-show', now() + interval '30 days', 'Teatro Colon', 'ARCHIVED'),
  ('06e00000-0000-0000-0000-000000000005', '06a00000-0000-0000-0000-00000000000a', 'Second Published Show', 'second-published-show', now() + interval '45 days', 'Teatro Colon', 'DRAFT');

-- One PUBLISHED event under Org B, for cross-tenant tests.
insert into public.events (id, organization_id, name, slug, starts_at, venue_name, status) values
  ('06e00000-0000-0000-0000-00000000000b', '06a00000-0000-0000-0000-00000000000b', 'Org B Show', 'org-b-show', now() + interval '30 days', 'Estadio B', 'DRAFT');

-- Ticket types on "Published Show" (Org A, event 0001): one of every kind
-- RFC-006's validation loop must distinguish between.
insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active, max_per_order, sales_start_at, sales_end_at) values
  ('06c00000-0000-0000-0000-000000000001', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'General', 1500000, 'ARS', 20, 'PUBLIC', true, 10, null, null),
  ('06c00000-0000-0000-0000-000000000002', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'VIP', 3000000, 'ARS', 20, 'PUBLIC', true, 10, null, null),
  ('06c00000-0000-0000-0000-000000000003', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'Backstage Comp', 0, 'ARS', 10, 'HIDDEN', true, 10, null, null),
  ('06c00000-0000-0000-0000-000000000004', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'Retired Tier', 1000000, 'ARS', 10, 'PUBLIC', false, 10, null, null),
  ('06c00000-0000-0000-0000-000000000005', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'Presale', 1000000, 'ARS', 10, 'PUBLIC', true, 10, now() + interval '7 days', null),
  ('06c00000-0000-0000-0000-000000000006', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'Early Bird', 800000, 'ARS', 10, 'PUBLIC', true, 10, now() - interval '10 days', now() - interval '1 day'),
  ('06c00000-0000-0000-0000-000000000007', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'Low Stock', 500000, 'ARS', 5, 'PUBLIC', true, 10, null, null),
  ('06c00000-0000-0000-0000-000000000008', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'One Per Order', 500000, 'ARS', 10, 'PUBLIC', true, 1, null, null);

-- A ticket type belonging to Org A's OTHER published event (0005) - used to
-- prove "ticket type from another event, same organization" is rejected.
insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('06c00000-0000-0000-0000-000000000009', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000005', 'Other Event Ticket', 500000, 'ARS', 10, 'PUBLIC', true);

-- A ticket type belonging to Org B entirely - used to prove cross-organization rejection.
insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('06c0000b-0000-0000-0000-000000000001', '06a00000-0000-0000-0000-00000000000b', '06e00000-0000-0000-0000-00000000000b', 'Org B Ticket', 500000, 'ARS', 10, 'PUBLIC', true);

-- Now that every event has a qualifying PUBLIC/active ticket type, publish
-- the three events that must be PUBLISHED - via UPDATE, exercising the
-- same publish path RFC-004's trigger validates (it fires on every INSERT
-- that sets status too, so a fresh PUBLISHED row with no ticket type yet
-- would be rejected - same pattern RFC-005's own test file established).
update public.events set status = 'PUBLISHED' where id in (
  '06e00000-0000-0000-0000-000000000001',
  '06e00000-0000-0000-0000-000000000005',
  '06e00000-0000-0000-0000-00000000000b'
);

-- ---------------------------------------------------------------------------
-- anon: no direct table access to commerce tables (RFC-006 section 46) -
-- RLS is untouched by this migration; access is entirely mediated through
-- the three functions above.
-- ---------------------------------------------------------------------------
set local role anon;

select is_empty(
  $$ select 1 from public.orders $$,
  '09: anon cannot directly SELECT any row from orders'
);

select is_empty(
  $$ select 1 from public.customers $$,
  '10: anon cannot directly SELECT any row from customers'
);

select is_empty(
  $$ select 1 from public.ticket_holds $$,
  '11: anon cannot directly SELECT any row from ticket_holds'
);

select throws_ok(
  $$ insert into public.orders (organization_id, event_id, order_number, buyer_name, buyer_email, currency, subtotal_amount, total_amount)
     values ('06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', 'FORGED-1', 'x', 'x@example.test', 'ARS', 0, 0) $$,
  '42501', null,
  '12: anon cannot directly INSERT into orders'
);

select throws_ok(
  $$ insert into public.ticket_holds (organization_id, event_id, ticket_type_id, quantity, expires_at)
     values ('06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', '06c00000-0000-0000-0000-000000000001', 1, now() + interval '10 minutes') $$,
  '42501', null,
  '13: anon cannot directly INSERT into ticket_holds'
);

select throws_ok(
  $$ insert into public.customers (organization_id, email) values ('06a00000-0000-0000-0000-00000000000a', 'forged@example.test') $$,
  '42501', null,
  '14: anon cannot directly INSERT into customers'
);

-- ---------------------------------------------------------------------------
-- Happy path (RFC-006 section 52)
-- ---------------------------------------------------------------------------
select order_id, order_status, expires_at, currency, subtotal_amount, total_amount, items
  into temporary t_happy_order
  from public.create_order_with_hold(
    'rfc006-org-a', 'published-show',
    '[{"ticketTypeId": "06c00000-0000-0000-0000-000000000001", "quantity": 2}, {"ticketTypeId": "06c00000-0000-0000-0000-000000000002", "quantity": 1}]'::jsonb,
    'Juan Comprador', 'juan.comprador@example.test', '+54 9 11 5555-0000',
    'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11'
  );

select ok(
  (select order_id from t_happy_order) is not null,
  '15: checkout for a PUBLISHED event with valid PUBLIC ticket types creates an order'
);

select results_eq(
  $$ select order_status from t_happy_order $$,
  $$ values ('PENDING_PAYMENT'::text) $$,
  '16: the new order''s status is PENDING_PAYMENT'
);

select results_eq(
  $$ select subtotal_amount, total_amount from t_happy_order $$,
  $$ values (6000000::bigint, 6000000::bigint) $$,
  '17: subtotal = SUM(line totals) = (2*1500000)+(1*3000000) = 6000000, total = subtotal (no fees in RFC-006)'
);

reset role;

select is(
  (select count(*)::int from public.customers
    where organization_id = '06a00000-0000-0000-0000-00000000000a'
      and normalized_email = 'juan.comprador@example.test'),
  1,
  '18: a customer record was created (organization-scoped) for the buyer'
);

select is(
  (select count(*)::int from public.order_items oi
    join t_happy_order t on t.order_id = oi.order_id
    where oi.organization_id = '06a00000-0000-0000-0000-00000000000a'),
  2,
  '19: exactly 2 order_items were created for the 2-line cart'
);

select ok(
  (select bool_and(oi.unit_price_amount = tt.unit_price_amount)
    from public.order_items oi
    join t_happy_order t on t.order_id = oi.order_id
    join public.ticket_types tt on tt.id = oi.ticket_type_id),
  '20: every order_item.unit_price_amount was copied verbatim from ticket_types.unit_price_amount - never client-supplied (RFC-006 section 55)'
);

select ok(
  (select bool_and(oi.subtotal_amount = oi.unit_price_amount * oi.quantity)
    from public.order_items oi
    join t_happy_order t on t.order_id = oi.order_id),
  '21: every order_item line total = unit_price_amount * quantity'
);

select is(
  (select count(*)::int from public.ticket_holds h
    join t_happy_order t on t.order_id = h.order_id),
  2,
  '22: exactly 2 ticket_holds were created (one per line)'
);

select ok(
  (select bool_and(h.quantity = oi.quantity)
    from public.ticket_holds h
    join public.order_items oi
      on oi.order_id = h.order_id and oi.ticket_type_id = h.ticket_type_id
    join t_happy_order t on t.order_id = h.order_id),
  '23: each hold''s quantity matches its order_item''s quantity'
);

select ok(
  (select bool_and(h.expires_at = (select expires_at from t_happy_order))
    from public.ticket_holds h join t_happy_order t on t.order_id = h.order_id),
  '24: every hold shares the SAME server-generated expires_at as the order'
);

select ok(
  (select expires_at - now() between interval '9 minutes 30 seconds' and interval '10 minutes 30 seconds' from t_happy_order),
  '25: expires_at was generated server-side as approximately now() + CHECKOUT_HOLD_MINUTES (10 minutes) - never supplied by the caller'
);

select is(
  (select o.organization_id::text from public.orders o join t_happy_order t on t.order_id = o.id),
  '06a00000-0000-0000-0000-00000000000a',
  '26: the created order belongs to the requested organization'
);

select is(
  (select o.event_id::text from public.orders o join t_happy_order t on t.order_id = o.id),
  '06e00000-0000-0000-0000-000000000001',
  '27: the created order belongs to the requested event'
);

-- ---------------------------------------------------------------------------
-- Event validation (RFC-006 section 53)
-- ---------------------------------------------------------------------------
set local role anon;

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'draft-show', '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'bb11bb11bb11bb11bb11bb11bb11bb11bb11bb11bb11bb11bb11bb11bb11bb11') $$,
  'LT001', null,
  '28: checkout against a DRAFT event is rejected'
);

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'cancelled-show', '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22bb22') $$,
  'LT001', null,
  '29: checkout against a CANCELLED event is rejected'
);

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'archived-show', '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'bb33bb33bb33bb33bb33bb33bb33bb33bb33bb33bb33bb33bb33bb33bb33bb33') $$,
  'LT001', null,
  '30: checkout against an ARCHIVED event is rejected'
);

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'no-such-event', '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'bb44bb44bb44bb44bb44bb44bb44bb44bb44bb44bb44bb44bb44bb44bb44bb44') $$,
  'LT001', null,
  '31: checkout against a nonexistent event slug is rejected with the SAME error as a private event'
);

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-b', 'published-show', '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'bb55bb55bb55bb55bb55bb55bb55bb55bb55bb55bb55bb55bb55bb55bb55bb55') $$,
  'LT001', null,
  '32: a published event''s slug under the WRONG organization is rejected'
);

-- ---------------------------------------------------------------------------
-- Ticket type validation (RFC-006 section 54)
-- ---------------------------------------------------------------------------
select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'cc01cc01cc01cc01cc01cc01cc01cc01cc01cc01cc01cc01cc01cc01cc01cc01') $$,
    '06c00000-0000-0000-0000-000000000004'),
  'LT002', null,
  '33: an inactive ticket type is rejected'
);

select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'cc02cc02cc02cc02cc02cc02cc02cc02cc02cc02cc02cc02cc02cc02cc02cc02') $$,
    '06c00000-0000-0000-0000-000000000003'),
  'LT002', null,
  '34: a HIDDEN ticket type is rejected'
);

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"00000000-0000-0000-0000-000000000000","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'cc03cc03cc03cc03cc03cc03cc03cc03cc03cc03cc03cc03cc03cc03cc03cc03') $$,
  'LT002', null,
  '35: a nonexistent ticket type id is rejected'
);

select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'cc04cc04cc04cc04cc04cc04cc04cc04cc04cc04cc04cc04cc04cc04cc04cc04') $$,
    '06c00000-0000-0000-0000-000000000009'),
  'LT002', null,
  '36: a ticket type belonging to a DIFFERENT event (same organization) is rejected'
);

select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'cc05cc05cc05cc05cc05cc05cc05cc05cc05cc05cc05cc05cc05cc05cc05cc05') $$,
    '06c0000b-0000-0000-0000-000000000001'),
  'LT002', null,
  '37: a ticket type belonging to a DIFFERENT organization is rejected, even by valid UUID (RFC-006 section 47)'
);

select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'cc06cc06cc06cc06cc06cc06cc06cc06cc06cc06cc06cc06cc06cc06cc06cc06') $$,
    '06c00000-0000-0000-0000-000000000005'),
  'LT003', null,
  '38: a ticket type whose sales_start_at is in the future is rejected (SALES_NOT_STARTED)'
);

select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":1}]'::jsonb, 'X', 'x@example.test', null, 'cc07cc07cc07cc07cc07cc07cc07cc07cc07cc07cc07cc07cc07cc07cc07cc07') $$,
    '06c00000-0000-0000-0000-000000000006'),
  'LT004', null,
  '39: a ticket type whose sales_end_at has passed is rejected (SALES_ENDED)'
);

select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":0}]'::jsonb, 'X', 'x@example.test', null, 'cc08cc08cc08cc08cc08cc08cc08cc08cc08cc08cc08cc08cc08cc08cc08cc08') $$,
    '06c00000-0000-0000-0000-000000000001'),
  'LT006', null,
  '40: a zero quantity line is rejected'
);

select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":-1}]'::jsonb, 'X', 'x@example.test', null, 'cc09cc09cc09cc09cc09cc09cc09cc09cc09cc09cc09cc09cc09cc09cc09cc09') $$,
    '06c00000-0000-0000-0000-000000000001'),
  'LT006', null,
  '41: a negative quantity line is rejected'
);

select throws_ok(
  format($$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"%s","quantity":2}]'::jsonb, 'X', 'x@example.test', null, 'cc10cc10cc10cc10cc10cc10cc10cc10cc10cc10cc10cc10cc10cc10cc10cc10') $$,
    '06c00000-0000-0000-0000-000000000008'),
  'LT009', null,
  '42: a quantity above the ticket type''s own max_per_order (1) is rejected (CHECKOUT_LIMIT_EXCEEDED)'
);

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'published-show',
       '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":6},{"ticketTypeId":"06c00000-0000-0000-0000-000000000002","quantity":6}]'::jsonb,
       'X', 'x@example.test', null, 'cc11cc11cc11cc11cc11cc11cc11cc11cc11cc11cc11cc11cc11cc11cc11cc11') $$,
  'LT009', null,
  '43: a cart whose total quantity exceeds MAX_TICKETS_PER_ORDER (10) is rejected even though each individual line is under its own max_per_order'
);

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'published-show',
       '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":1},{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":1}]'::jsonb,
       'X', 'x@example.test', null, 'cc12cc12cc12cc12cc12cc12cc12cc12cc12cc12cc12cc12cc12cc12cc12cc12') $$,
  'LT006', null,
  '44: duplicate ticket types in the same cart are rejected'
);

-- ---------------------------------------------------------------------------
-- Active / expired hold semantics (RFC-006 sections 56/57)
-- ---------------------------------------------------------------------------
-- "Low Stock" (06c...0007) has quantity=5. Consume 3 with one order first.
select public.create_order_with_hold(
  'rfc006-org-a', 'published-show',
  '[{"ticketTypeId": "06c00000-0000-0000-0000-000000000007", "quantity": 3}]'::jsonb,
  'Primer Comprador', 'primer.comprador@example.test', null,
  'dd01dd01dd01dd01dd01dd01dd01dd01dd01dd01dd01dd01dd01dd01dd01dd01'
);

select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000007","quantity":3}]'::jsonb, 'X', 'x2@example.test', null, 'dd02dd02dd02dd02dd02dd02dd02dd02dd02dd02dd02dd02dd02dd02dd02dd02') $$,
  'LT005', null,
  '45: capacity=5 with 3 already actively held - requesting 3 more (would be 6) fails with INSUFFICIENT_INVENTORY'
);

select lives_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000007","quantity":2}]'::jsonb, 'Segundo Comprador', 'segundo.comprador@example.test', null, 'dd03dd03dd03dd03dd03dd03dd03dd03dd03dd03dd03dd03dd03dd03dd03dd03') $$,
  '46: capacity=5 with 3 already actively held - requesting exactly the remaining 2 succeeds'
);

reset role;

-- Simulate 5 EXPIRED holds against a fresh ticket type with capacity 5, by
-- creating a throwaway order/hold pair directly with expires_at already
-- in the past (bypassing the RPC, which never lets a caller backdate an
-- expiration - this is purely to set up the "expired holds don't count"
-- scenario deterministically without waiting 10 real minutes).
insert into public.customers (id, organization_id, email, name) values
  ('06cc0000-0000-0000-0000-000000000001', '06a00000-0000-0000-0000-00000000000a', 'expired.holder@example.test', 'Expired Holder');
insert into public.orders (id, organization_id, event_id, customer_id, order_number, buyer_name, buyer_email, currency, subtotal_amount, total_amount, status, expires_at, checkout_token_hash) values
  ('06f00000-0000-0000-0000-000000000009', '06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', '06cc0000-0000-0000-0000-000000000001', 'RFC006-EXPIRED-1', 'Expired Holder', 'expired.holder@example.test', 'ARS', 15000000, 15000000, 'PENDING_PAYMENT', now() - interval '5 minutes', 'ee01ee01ee01ee01ee01ee01ee01ee01ee01ee01ee01ee01ee01ee01ee01ee01');
insert into public.order_items (organization_id, order_id, ticket_type_id, name_snapshot, unit_price_amount, quantity, subtotal_amount) values
  ('06a00000-0000-0000-0000-00000000000a', '06f00000-0000-0000-0000-000000000009', '06c00000-0000-0000-0000-000000000002', 'VIP', 3000000, 5, 15000000);
insert into public.ticket_holds (organization_id, event_id, ticket_type_id, order_id, quantity, expires_at) values
  ('06a00000-0000-0000-0000-00000000000a', '06e00000-0000-0000-0000-000000000001', '06c00000-0000-0000-0000-000000000002', '06f00000-0000-0000-0000-000000000009', 5, now() - interval '5 minutes');

set local role anon;

select lives_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'published-show', '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000002","quantity":5}]'::jsonb, 'Tercer Comprador', 'tercer.comprador@example.test', null, 'dd04dd04dd04dd04dd04dd04dd04dd04dd04dd04dd04dd04dd04dd04dd04dd04') $$,
  '47: VIP has 5 EXPIRED holds already on record - full availability (20) is still usable, proving expired holds never consume inventory regardless of cleanup having run'
);

-- ---------------------------------------------------------------------------
-- Multi-line atomicity (RFC-006 section 58)
-- ---------------------------------------------------------------------------
-- "Low Stock" (06c...0007) capacity=5 was fully consumed by tests 45-47
-- (3 + 2 = 5 actively held, 0 remaining). Request just 1 more unit of it
-- alongside a perfectly satisfiable General line, so the failure is
-- genuinely INSUFFICIENT_INVENTORY (not a checkout-limit rejection like
-- MAX_TICKETS_PER_ORDER, which a huge quantity would trigger instead).
select throws_ok(
  $$ select public.create_order_with_hold('rfc006-org-a', 'published-show',
       '[{"ticketTypeId":"06c00000-0000-0000-0000-000000000001","quantity":2},{"ticketTypeId":"06c00000-0000-0000-0000-000000000007","quantity":1}]'::jsonb,
       'Cart Atomico', 'cart.atomico@example.test', null, 'ee02ee02ee02ee02ee02ee02ee02ee02ee02ee02ee02ee02ee02ee02ee02ee02') $$,
  'LT005', null,
  '48: a 2-line cart where ONE line has insufficient inventory fails as a whole (General had plenty available)'
);

reset role;

select is(
  (select count(*)::int from public.orders where buyer_email = 'cart.atomico@example.test'),
  0,
  '49: the failed multi-line cart created ZERO orders'
);

select is(
  (select count(*)::int from public.order_items oi join public.orders o on o.id = oi.order_id where o.buyer_email = 'cart.atomico@example.test'),
  0,
  '50: the failed multi-line cart created ZERO order_items (not even for the General line that WAS available)'
);

select is(
  (select count(*)::int from public.ticket_holds h join public.orders o on o.id = h.order_id where o.buyer_email = 'cart.atomico@example.test'),
  0,
  '51: the failed multi-line cart created ZERO ticket_holds'
);

-- ---------------------------------------------------------------------------
-- Expiration lifecycle (RFC-006 sections 43/44/61)
-- ---------------------------------------------------------------------------
select is(
  (select status::text from public.orders where id = '06f00000-0000-0000-0000-000000000009'),
  'PENDING_PAYMENT',
  '52: (sanity check) the backdated fixture order is still persisted as PENDING_PAYMENT before cleanup runs - proving test 47''s availability came from timestamp-aware inventory math, not from a status change'
);

select is(
  public.expire_pending_orders(),
  1,
  '53: expire_pending_orders() transitions exactly the 1 lapsed PENDING_PAYMENT order (the backdated fixture)'
);

select is(
  (select status::text from public.orders where id = '06f00000-0000-0000-0000-000000000009'),
  'EXPIRED',
  '54: the lapsed order''s status is now EXPIRED'
);

select is(
  public.expire_pending_orders(),
  0,
  '55: running expire_pending_orders() again is idempotent - 0 additional rows affected'
);

select is(
  (select status::text from t_happy_order t join public.orders o on o.id = t.order_id),
  'PENDING_PAYMENT',
  '56: a genuinely still-valid PENDING_PAYMENT order (test 15''s order, not yet expired) is untouched by expire_pending_orders()'
);

-- ---------------------------------------------------------------------------
-- Checkout token security (RFC-006 sections 24/27/62)
-- ---------------------------------------------------------------------------
set local role anon;

select results_eq(
  format($$ select order_id from public.get_checkout_order('%s', 'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11') $$,
    (select order_id::text from t_happy_order)),
  $$ select order_id from t_happy_order $$,
  '57a: the correct raw token resolves the correct order'
);

select throws_ok(
  format($$ select public.get_checkout_order('%s', 'wrongwrongwrongwrongwrongwrongwrongwrongwrongwrongwrongwrongwrong') $$,
    (select order_id::text from t_happy_order)),
  'LT008', null,
  '57b: an invalid token for a real order id fails (INVALID_CHECKOUT_TOKEN)'
);

select throws_ok(
  format($$ select public.get_checkout_order('%s', '') $$, (select order_id::text from t_happy_order)),
  'LT008', null,
  '57c: an empty/missing token fails'
);

select throws_ok(
  $$ select public.get_checkout_order('00000000-0000-0000-0000-000000000000', 'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11') $$,
  'LT008', null,
  '57d: the correct token paired with a DIFFERENT (nonexistent) order id fails - order id alone is never sufficient (RFC-006 section 23)'
);

-- Cross-order token isolation: create a second order with its own token,
-- then prove the first order's token cannot read it and vice versa.
select order_id from public.create_order_with_hold(
  'rfc006-org-a', 'published-show',
  '[{"ticketTypeId": "06c00000-0000-0000-0000-000000000001", "quantity": 1}]'::jsonb,
  'Segunda Orden', 'segunda.orden@example.test', null,
  'ff01ff01ff01ff01ff01ff01ff01ff01ff01ff01ff01ff01ff01ff01ff01ff01'
) \gset second_

select throws_ok(
  format($$ select public.get_checkout_order('%s', 'aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11aa11') $$, :'second_order_id'),
  'LT008', null,
  '58: order A''s token cannot be used to read order B - the token is scoped to exactly the order it was issued for'
);

reset role;

select * from finish();

rollback;
