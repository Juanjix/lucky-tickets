-- RFC-002 database security & integrity test suite (pgTAP).
--
-- Run via the Supabase CLI once a local stack is available:
--   supabase test db
--
-- pgTAP ships with the Supabase local Postgres image, so no extra install
-- step is needed there. This file assumes the real `auth` schema /
-- `auth.uid()` / anon,authenticated,service_role roles that a Supabase
-- project always provides - it does not create them.
--
-- Auth simulation: PostgREST (what actually serves Supabase's API) sets
-- the `request.jwt.claim.sub` GUC and the session role per request; this
-- file reproduces that directly with `set_config(...)` + `set local role`
-- to exercise the exact same RLS policies a real request would.
--
-- Maps to RFC-002 section 37's required tests 01-10; each is labeled below.
-- Additional assertions cover role-matrix cases the RFC calls out
-- explicitly elsewhere (audience/payment protection, check-in uniqueness,
-- the organization bootstrap policy) without being asked for by number.

begin;

create extension if not exists pgtap with schema extensions;

select plan(22);

-- ---------------------------------------------------------------------------
-- Fixtures (inserted as the table owner, bypassing RLS, which is normal for
-- test setup - the assertions below are what actually exercises RLS).
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('11111111-1111-1111-1111-111111111111', 'owner-a@example.test'),
  ('22222222-2222-2222-2222-222222222222', 'owner-b@example.test'),
  ('33333333-3333-3333-3333-333333333333', 'door-a@example.test'),
  ('44444444-4444-4444-4444-444444444444', 'viewer-a@example.test'),
  ('55555555-5555-5555-5555-555555555555', 'newcomer@example.test');

insert into public.organizations (id, name, slug) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'Org A', 'org-a'),
  ('bbbbbbbb-0000-0000-0000-000000000002', 'Org B', 'org-b');

insert into public.organization_members (organization_id, user_id, role) values
  ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'OWNER'),
  ('bbbbbbbb-0000-0000-0000-000000000002', '22222222-2222-2222-2222-222222222222', 'OWNER'),
  ('aaaaaaaa-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'DOOR_STAFF'),
  ('aaaaaaaa-0000-0000-0000-000000000001', '44444444-4444-4444-4444-444444444444', 'VIEWER');

insert into public.events (id, organization_id, name, slug, starts_at) values
  ('eeeeeeee-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'Event A', 'event-a', now() + interval '1 day'),
  ('eeeeeeee-0000-0000-0000-000000000002', 'bbbbbbbb-0000-0000-0000-000000000002', 'Event B', 'event-b', now() + interval '1 day');

insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity) values
  ('11110000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'General', 100000, 'ARS', 100);

insert into public.customers (id, organization_id, email) values
  ('c0000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'buyer@example.test');

insert into public.orders (id, organization_id, event_id, customer_id, order_number, buyer_name, buyer_email, currency, subtotal_amount, service_fee_amount, total_amount, status) values
  ('00000000-0000-0000-0000-00000000000a', 'aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'c0000000-0000-0000-0000-000000000001', 'A-0001', 'Buyer One', 'buyer@example.test', 'ARS', 100000, 5000, 105000, 'PAID');

insert into public.order_items (id, organization_id, order_id, ticket_type_id, name_snapshot, unit_price_amount, quantity, subtotal_amount) values
  ('01000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '11110000-0000-0000-0000-000000000001', 'General', 100000, 1, 100000);

insert into public.payments (id, organization_id, order_id, provider, provider_payment_id, status, paid_amount, currency) values
  ('9a000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', 'MERCADO_PAGO', 'mp-payment-001', 'APPROVED', 105000, 'ARS');

insert into public.tickets (id, organization_id, event_id, order_id, order_item_id, ticket_type_id, ticket_number, status) values
  ('7a000000-0000-0000-0000-000000000001', 'aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', '00000000-0000-0000-0000-00000000000a', '01000000-0000-0000-0000-000000000001', '11110000-0000-0000-0000-000000000001', 'A-T-0001', 'VALID');

insert into public.billing_accounts (organization_id, fee_type, fee_percentage_bps) values
  ('aaaaaaaa-0000-0000-0000-000000000001', 'PERCENTAGE', 500);

-- ---------------------------------------------------------------------------
-- Test 01: member of Org A can read permitted Org A data.
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select isnt_empty(
  $$ select 1 from public.events where id = 'eeeeeeee-0000-0000-0000-000000000001' $$,
  '01a: OWNER of Org A can read Org A''s own event'
);

select isnt_empty(
  $$ select 1 from public.ticket_types where id = '11110000-0000-0000-0000-000000000001' $$,
  '01b: OWNER of Org A can read Org A''s own ticket type'
);

-- ---------------------------------------------------------------------------
-- Test 02: member of Org A cannot read Org B tenant data.
-- ---------------------------------------------------------------------------
select is_empty(
  $$ select 1 from public.events where id = 'eeeeeeee-0000-0000-0000-000000000002' $$,
  '02a: OWNER of Org A cannot read Org B''s event'
);

select is_empty(
  $$ select 1 from public.organizations where id = 'bbbbbbbb-0000-0000-0000-000000000002' $$,
  '02b: OWNER of Org A cannot read the Org B organization row'
);

-- ---------------------------------------------------------------------------
-- Test 03: member of Org A cannot create a business record tied to Org B.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.events (organization_id, name, slug, starts_at)
     values ('bbbbbbbb-0000-0000-0000-000000000002', 'Hostile Event', 'hostile-event', now() + interval '1 day') $$,
  '42501',
  null,
  '03: OWNER of Org A cannot insert an event into Org B'
);

-- ---------------------------------------------------------------------------
-- Test 04: unauthenticated user cannot read private tenant data.
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claim.sub', '', true);
set local role anon;

select is_empty(
  $$ select 1 from public.events $$,
  '04a: anonymous cannot read any events'
);

select is_empty(
  $$ select 1 from public.organizations $$,
  '04b: anonymous cannot read any organizations'
);

-- ---------------------------------------------------------------------------
-- Test 05 / 06: DOOR_STAFF cannot read billing data / payment data.
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', true);

select is_empty(
  $$ select 1 from public.billing_accounts where organization_id = 'aaaaaaaa-0000-0000-0000-000000000001' $$,
  '05: DOOR_STAFF cannot read Org A''s billing_accounts'
);

select is_empty(
  $$ select 1 from public.payments $$,
  '06: DOOR_STAFF cannot read payments'
);

-- Bonus: the same "operational but not financial/audience" boundary,
-- exercised on two more tables the RFC calls out by name.
select is_empty(
  $$ select 1 from public.customers $$,
  'bonus: DOOR_STAFF cannot read customers (audience data)'
);

select is_empty(
  $$ select 1 from public.orders $$,
  'bonus: DOOR_STAFF cannot read orders'
);

-- But DOOR_STAFF *can* see tickets - they need to, to do their job.
select isnt_empty(
  $$ select 1 from public.tickets where id = '7a000000-0000-0000-0000-000000000001' $$,
  'bonus: DOOR_STAFF can read a ticket in their own org'
);

-- ---------------------------------------------------------------------------
-- Test 07: VIEWER cannot perform protected mutations.
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '44444444-4444-4444-4444-444444444444', true);

select throws_ok(
  $$ insert into public.events (organization_id, name, slug, starts_at)
     values ('aaaaaaaa-0000-0000-0000-000000000001', 'Viewer Event', 'viewer-event', now() + interval '1 day') $$,
  '42501',
  null,
  '07: VIEWER cannot insert an event, even in their own org'
);

-- ---------------------------------------------------------------------------
-- Test 08: duplicate organization membership is rejected.
-- ---------------------------------------------------------------------------
reset role;
select set_config('request.jwt.claim.sub', '', true);

select throws_ok(
  $$ insert into public.organization_members (organization_id, user_id, role)
     values ('aaaaaaaa-0000-0000-0000-000000000001', '11111111-1111-1111-1111-111111111111', 'ADMIN') $$,
  '23505',
  null,
  '08: duplicate (organization_id, user_id) membership is rejected'
);

-- ---------------------------------------------------------------------------
-- Test 09: cross-tenant foreign-key/domain relationships are rejected.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.ticket_types (organization_id, event_id, name, unit_price_amount, currency, quantity)
     values ('aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000002', 'Cross Tenant', 100000, 'ARS', 10) $$,
  '23503',
  null,
  '09: a ticket_type cannot reference an event belonging to a different organization'
);

-- ---------------------------------------------------------------------------
-- Test 10: invalid monetary values / quantities are rejected by constraints.
-- ---------------------------------------------------------------------------
select throws_ok(
  $$ insert into public.ticket_types (organization_id, event_id, name, unit_price_amount, currency, quantity)
     values ('aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'Negative Price', -100, 'ARS', 10) $$,
  '23514',
  null,
  '10a: negative unit_price_amount is rejected'
);

select throws_ok(
  $$ insert into public.ticket_types (organization_id, event_id, name, unit_price_amount, currency, quantity)
     values ('aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'Zero Quantity', 100000, 'ARS', 0) $$,
  '23514',
  null,
  '10b: zero quantity is rejected'
);

select throws_ok(
  $$ insert into public.orders (organization_id, event_id, order_number, buyer_name, buyer_email, currency, subtotal_amount, service_fee_amount, total_amount)
     values ('aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'A-BAD-1', 'Bad Buyer', 'bad@example.test', 'ARS', 100000, 5000, 999999) $$,
  '23514',
  null,
  '10c: order total_amount inconsistent with subtotal + service_fee is rejected'
);

-- ---------------------------------------------------------------------------
-- Bonus: positive control - a correctly-scoped, same-organization insert by
-- an authorized role succeeds (proves the policies above deny by design,
-- not because every insert is broken).
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claim.sub', '11111111-1111-1111-1111-111111111111', true);

select lives_ok(
  $$ insert into public.ticket_types (organization_id, event_id, name, unit_price_amount, currency, quantity)
     values ('aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', 'VIP', 200000, 'ARS', 10) $$,
  'bonus: OWNER of Org A can insert a ticket_type for Org A''s own event'
);

-- Bonus: DOOR_STAFF can record a check-in for a ticket in their org...
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '33333333-3333-3333-3333-333333333333', true);

select lives_ok(
  $$ insert into public.check_ins (organization_id, event_id, ticket_id, checked_in_by, gate)
     values ('aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', '7a000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'Main') $$,
  'bonus: DOOR_STAFF can insert a check-in for a ticket in their own org'
);

-- ...but a second check-in for the SAME ticket is rejected at the database
-- level (UNIQUE(ticket_id) on check_ins), independent of any future
-- application-level "atomic check-in" logic.
select throws_ok(
  $$ insert into public.check_ins (organization_id, event_id, ticket_id, checked_in_by, gate)
     values ('aaaaaaaa-0000-0000-0000-000000000001', 'eeeeeeee-0000-0000-0000-000000000001', '7a000000-0000-0000-0000-000000000001', '33333333-3333-3333-3333-333333333333', 'Side') $$,
  '23505',
  null,
  'bonus: a second check-in for the same ticket is rejected (UNIQUE(ticket_id))'
);

-- ---------------------------------------------------------------------------
-- Bonus: the organization_members bootstrap policy - a brand-new
-- authenticated user can create an organization and immediately become its
-- OWNER, but only once (the bootstrap window closes after the first member).
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', '55555555-5555-5555-5555-555555555555', true);

insert into public.organizations (id, name, slug)
values ('cccccccc-0000-0000-0000-000000000003', 'Org C', 'org-c');

select lives_ok(
  $$ insert into public.organization_members (organization_id, user_id, role)
     values ('cccccccc-0000-0000-0000-000000000003', '55555555-5555-5555-5555-555555555555', 'OWNER') $$,
  'bonus: a new authenticated user can bootstrap themselves as OWNER of their own new organization'
);

select * from finish();

rollback;
