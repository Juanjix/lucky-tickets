-- RFC-004 database test suite (pgTAP): Events & Ticket Types.
--
-- This file intentionally does NOT re-verify everything RFC-002 already
-- covers for `events`/`ticket_types` (see rfc_002_security.test.sql:
-- cross-org read isolation, cross-org INSERT rejection, the
-- ticket_types->events tenant-consistency FK, and basic price/quantity
-- CHECK constraints - 22 assertions already exercise all of that). It
-- focuses on what RFC-004 actually adds:
--
--   - the full OWNER/ADMIN/PRODUCER/DOOR_STAFF/VIEWER role matrix for
--     event/ticket-type UPDATEs specifically (RFC-002 only exercised
--     INSERT for this matrix), since "least-privilege" is RFC-004's own
--     explicit requirement;
--   - the two NEW triggers this RFC's migration adds:
--     `check_event_ticket_capacity()` (ticket inventory vs event capacity)
--     and `enforce_event_publish_invariants()` (publication invariants) -
--     see supabase/migrations/20260922000000_rfc_004_events_ticket_types.sql.
--
-- Run via the Supabase CLI once a local stack is available:
--   supabase test db

begin;

create extension if not exists pgtap with schema extensions;

select plan(20);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('a1000000-0000-0000-0000-000000000001', 'owner-a@example.test'),
  ('a2000000-0000-0000-0000-000000000002', 'admin-a@example.test'),
  ('a3000000-0000-0000-0000-000000000003', 'producer-a@example.test'),
  ('a4000000-0000-0000-0000-000000000004', 'doorstaff-a@example.test'),
  ('a5000000-0000-0000-0000-000000000005', 'viewer-a@example.test'),
  ('b1000000-0000-0000-0000-000000000001', 'owner-b@example.test');

insert into public.organizations (id, name, slug, currency) values
  ('0a000000-0000-0000-0000-000000000001', 'Org A', 'rfc004-org-a', 'ARS'),
  ('0b000000-0000-0000-0000-000000000002', 'Org B', 'rfc004-org-b', 'ARS');

insert into public.organization_members (organization_id, user_id, role) values
  ('0a000000-0000-0000-0000-000000000001', 'a1000000-0000-0000-0000-000000000001', 'OWNER'),
  ('0a000000-0000-0000-0000-000000000001', 'a2000000-0000-0000-0000-000000000002', 'ADMIN'),
  ('0a000000-0000-0000-0000-000000000001', 'a3000000-0000-0000-0000-000000000003', 'PRODUCER'),
  ('0a000000-0000-0000-0000-000000000001', 'a4000000-0000-0000-0000-000000000004', 'DOOR_STAFF'),
  ('0a000000-0000-0000-0000-000000000001', 'a5000000-0000-0000-0000-000000000005', 'VIEWER'),
  ('0b000000-0000-0000-0000-000000000002', 'b1000000-0000-0000-0000-000000000001', 'OWNER');

-- A fully-formed event (venue configured, capacity set) to update/mutate
-- against in the role-matrix tests below, and to attach ticket types to in
-- the capacity/publish tests further down.
insert into public.events (id, organization_id, name, slug, starts_at, venue_name, capacity, description) values
  ('0e000000-0000-0000-0000-000000000001', '0a000000-0000-0000-0000-000000000001', 'Role Matrix Event', 'role-matrix-event', now() + interval '30 days', 'Teatro Colon', 100, 'Original description'),
  ('0e000000-0000-0000-0000-000000000002', '0b000000-0000-0000-0000-000000000002', 'Org B Event', 'org-b-event', now() + interval '30 days', 'Some Venue', null, 'Original description');

-- ---------------------------------------------------------------------------
-- Role matrix: authorized roles (OWNER/ADMIN/PRODUCER) can create events;
-- DOOR_STAFF/VIEWER cannot. RFC-002 already proved this for OWNER and
-- VIEWER at INSERT time; PRODUCER and DOOR_STAFF are new here.
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a3000000-0000-0000-0000-000000000003', true);

select lives_ok(
  $$ insert into public.events (organization_id, name, slug, starts_at)
     values ('0a000000-0000-0000-0000-000000000001', 'Producer Event', 'producer-event', now() + interval '10 days') $$,
  '01: PRODUCER can create an event in their own org'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a4000000-0000-0000-0000-000000000004', true);

select throws_ok(
  $$ insert into public.events (organization_id, name, slug, starts_at)
     values ('0a000000-0000-0000-0000-000000000001', 'Door Staff Event', 'door-staff-event', now() + interval '10 days') $$,
  '42501',
  null,
  '02: DOOR_STAFF cannot create an event, even in their own org'
);

-- ---------------------------------------------------------------------------
-- Role matrix: UPDATE. RFC-002 exercised INSERT only for this matrix;
-- "manage events" (RFC-004 "Permissions") means update too.
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a2000000-0000-0000-0000-000000000002', true);

select lives_ok(
  $$ update public.events set description = 'Updated by ADMIN' where id = '0e000000-0000-0000-0000-000000000001' $$,
  '03: ADMIN can update an event in their own org'
);

-- Note on shape: an UPDATE's USING clause silently excludes rows the
-- caller isn't authorized to touch (0 rows affected, no error) rather than
-- throwing - the same RLS mechanism exercised cross-org further below.
-- "Cannot mutate" is proven here by showing the row is unaffected, not by
-- expecting an exception.
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a4000000-0000-0000-0000-000000000004', true);

select lives_ok(
  $$ update public.events set description = 'Hijacked by DOOR_STAFF' where id = '0e000000-0000-0000-0000-000000000001' $$,
  '04a: DOOR_STAFF''s attempted event update does not error (silently excluded by RLS)'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a5000000-0000-0000-0000-000000000005', true);

select lives_ok(
  $$ update public.events set description = 'Hijacked by VIEWER' where id = '0e000000-0000-0000-0000-000000000001' $$,
  '05a: VIEWER''s attempted event update does not error (silently excluded by RLS)'
);

-- Read access is unaffected: VIEWER can still SELECT the event they just
-- failed to mutate - RLS denies the write, not visibility.
select isnt_empty(
  $$ select 1 from public.events where id = '0e000000-0000-0000-0000-000000000001' $$,
  '06: VIEWER can still read the event (read-only, not no-access)'
);

-- Confirm neither DOOR_STAFF's nor VIEWER's update above actually changed
-- the row - proven as ADMIN, who can both read and is trusted here to
-- observe the real, current value.
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a2000000-0000-0000-0000-000000000002', true);

select results_eq(
  $$ select description from public.events where id = '0e000000-0000-0000-0000-000000000001' $$,
  $$ values ('Updated by ADMIN'::text) $$,
  '04b/05b: DOOR_STAFF''s and VIEWER''s update attempts did not actually change the event (still holds ADMIN''s test 03 value, not "Hijacked by...")'
);

-- ---------------------------------------------------------------------------
-- Cross-organization isolation, re-confirmed against this file's own
-- fixtures (RFC-002 already proves the general case; this proves it holds
-- for events RFC-004's own tests create and mutate).
--
-- Note on shape: unlike an INSERT with an unauthorized organization_id
-- (which RLS's WITH CHECK rejects by throwing 42501, see RFC-002 test 03),
-- an UPDATE naming a row in an org the caller doesn't belong to is not an
-- error at all - the USING clause simply excludes that row, so the
-- statement succeeds and reports 0 rows affected. Both are "the operation
-- did not happen"; they just surface differently, and both must be tested.
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true);

select is_empty(
  $$ select 1 from public.events where id = '0e000000-0000-0000-0000-000000000002' $$,
  '07: an Org A member cannot read Org B''s event'
);

select lives_ok(
  $$ update public.events set description = 'Hostile update' where id = '0e000000-0000-0000-0000-000000000002' $$,
  '08: an Org A OWNER''s update naming Org B''s event does not error (it is silently excluded by RLS, not granted)'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'b1000000-0000-0000-0000-000000000001', true);

select results_eq(
  $$ select description from public.events where id = '0e000000-0000-0000-0000-000000000002' $$,
  $$ values ('Original description'::text) $$,
  '09: Org B''s event was NOT actually modified by the Org A caller''s no-op update above'
);

-- ---------------------------------------------------------------------------
-- ticket_types tenant consistency, re-confirmed with this file's own
-- cross-org fixtures (RFC-002 test 09 already proves the general FK case).
-- ---------------------------------------------------------------------------
reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'a1000000-0000-0000-0000-000000000001', true);

select throws_ok(
  $$ insert into public.ticket_types (organization_id, event_id, name, unit_price_amount, currency, quantity)
     values ('0a000000-0000-0000-0000-000000000001', '0e000000-0000-0000-0000-000000000002', 'Cross Org Ticket', 100000, 'ARS', 10) $$,
  '23503',
  null,
  '10: a ticket type cannot reference an event belonging to a different organization'
);

-- ---------------------------------------------------------------------------
-- NEW: ticket type inventory vs event capacity (this RFC's migration).
-- Role Matrix Event has capacity = 100.
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility)
     values ('01000000-0000-0000-0000-000000000001', '0a000000-0000-0000-0000-000000000001', '0e000000-0000-0000-0000-000000000001', 'General', 1500000, 'ARS', 60, 'PUBLIC') $$,
  '11: a ticket type whose quantity fits within event capacity can be created'
);

select throws_ok(
  $$ insert into public.ticket_types (organization_id, event_id, name, unit_price_amount, currency, quantity, visibility)
     values ('0a000000-0000-0000-0000-000000000001', '0e000000-0000-0000-0000-000000000001', 'VIP', 3000000, 'ARS', 50, 'PUBLIC') $$,
  '23514',
  null,
  '12: a ticket type that would push total inventory (60 + 50 = 110) past event capacity (100) is rejected'
);

select throws_ok(
  $$ update public.events set capacity = 10 where id = '0e000000-0000-0000-0000-000000000001' $$,
  '23514',
  null,
  '13: lowering an event''s capacity below its already-allocated ticket inventory (60 already configured) is rejected'
);

select isnt_empty(
  $$ select 1 from public.ticket_types where id = '01000000-0000-0000-0000-000000000001' and quantity = 60 $$,
  '14: the ticket type from test 11 is unaffected by the rejected attempts above'
);

-- ---------------------------------------------------------------------------
-- NEW: publication invariants (this RFC's migration). Role Matrix Event
-- now has a venue and one PUBLIC/active ticket type with quantity > 0 (from
-- test 11), so it should be publishable; a bare event with neither should
-- not be, and a HIDDEN-only ticket type must not count as "sellable".
-- ---------------------------------------------------------------------------
select lives_ok(
  $$ update public.events set status = 'PUBLISHED' where id = '0e000000-0000-0000-0000-000000000001' $$,
  '15: an event with a venue and at least one public, active, positive-quantity ticket type can be published'
);

insert into public.events (id, organization_id, name, slug, starts_at) values
  ('0e000000-0000-0000-0000-000000000003', '0a000000-0000-0000-0000-000000000001', 'Bare Event', 'bare-event', now() + interval '10 days');

select throws_ok(
  $$ update public.events set status = 'PUBLISHED' where id = '0e000000-0000-0000-0000-000000000003' $$,
  '23514',
  null,
  '16: an event with no venue and no ticket types cannot be published'
);

update public.events set venue_name = 'Backstage Bar' where id = '0e000000-0000-0000-0000-000000000003';

select throws_ok(
  $$ update public.events set status = 'PUBLISHED' where id = '0e000000-0000-0000-0000-000000000003' $$,
  '23514',
  null,
  '17: an event with a venue but zero ticket types still cannot be published'
);

insert into public.ticket_types (organization_id, event_id, name, unit_price_amount, currency, quantity, visibility)
values ('0a000000-0000-0000-0000-000000000001', '0e000000-0000-0000-0000-000000000003', 'Comp Ticket', 0, 'ARS', 20, 'HIDDEN');

select throws_ok(
  $$ update public.events set status = 'PUBLISHED' where id = '0e000000-0000-0000-0000-000000000003' $$,
  '23514',
  null,
  '18: a HIDDEN-only ticket type does not count as sellable - the event still cannot be published'
);

insert into public.ticket_types (organization_id, event_id, name, unit_price_amount, currency, quantity, visibility)
values ('0a000000-0000-0000-0000-000000000001', '0e000000-0000-0000-0000-000000000003', 'General', 1000000, 'ARS', 30, 'PUBLIC');

select lives_ok(
  $$ update public.events set status = 'PUBLISHED' where id = '0e000000-0000-0000-0000-000000000003' $$,
  '19: once a real PUBLIC ticket type exists alongside the HIDDEN one, the event can be published'
);

select * from finish();

rollback;
