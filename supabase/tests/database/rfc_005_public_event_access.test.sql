-- RFC-005 database test suite (pgTAP): Public Event Page.
--
-- This file exercises the new `anon`-scoped policies from
-- supabase/migrations/20260923000000_rfc_005_public_event_access.sql. It
-- does not re-test anything RFC-002/RFC-003/RFC-004 already cover for
-- `authenticated` organizer access (unchanged by this RFC) - see
-- rfc_002_security.test.sql tests 04a/04b for the pre-RFC-005 baseline
-- ("anonymous cannot read any events/organizations" - still true here,
-- since those fixtures are DRAFT; RFC-005 only ever adds visibility for
-- PUBLISHED events, never takes it away).
--
-- Note on "quantity > 0" (part of the public-visibility predicate on
-- ticket_types in the RFC-005 migration): RFC-002's own
-- `ticket_types_quantity_positive` CHECK constraint already guarantees
-- quantity is always > 0 for any row that exists at all, so a "zero
-- quantity, otherwise-eligible" ticket type is not a reachable state to
-- fixture here - the RLS clause is defense in depth for if that CHECK
-- constraint is ever relaxed, not something this suite can exercise today.
--
-- Run via the Supabase CLI once a local stack is available:
--   supabase test db

begin;

create extension if not exists pgtap with schema extensions;

select plan(18);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('f1000000-0000-0000-0000-000000000001', 'owner-a@example.test');

insert into public.organizations (id, name, slug, currency, timezone) values
  ('05000000-0000-0000-0000-00000000000a', 'Lucky Losers', 'rfc005-lucky-losers', 'ARS', 'America/Argentina/Buenos_Aires'),
  ('05000000-0000-0000-0000-00000000000b', 'Org With No Published Events', 'rfc005-org-b', 'ARS', 'America/Argentina/Buenos_Aires');

insert into public.organization_members (organization_id, user_id, role) values
  ('05000000-0000-0000-0000-00000000000a', 'f1000000-0000-0000-0000-000000000001', 'OWNER');

-- One event per persisted status, all in the SAME organization, so that
-- "wrong status" and "wrong organization" are each isolated to their own
-- assertions below. All inserted as DRAFT first: RFC-004's
-- `enforce_event_publish_invariants()` trigger fires on every INSERT (it
-- checks `new.status`), so an event can only ever become PUBLISHED once it
-- already has a qualifying ticket type - the "Published Show" event below
-- is promoted to PUBLISHED via a follow-up UPDATE, after its ticket types
-- exist.
insert into public.events (id, organization_id, name, slug, starts_at, venue_name, status) values
  ('05e00000-0000-0000-0000-000000000001', '05000000-0000-0000-0000-00000000000a', 'Published Show', 'published-show', now() + interval '30 days', 'Teatro Colon', 'DRAFT'),
  ('05e00000-0000-0000-0000-000000000002', '05000000-0000-0000-0000-00000000000a', 'Draft Show', 'draft-show', now() + interval '30 days', 'Teatro Colon', 'DRAFT'),
  ('05e00000-0000-0000-0000-000000000003', '05000000-0000-0000-0000-00000000000a', 'Finished Show', 'finished-show', now() - interval '10 days', 'Teatro Colon', 'FINISHED'),
  ('05e00000-0000-0000-0000-000000000004', '05000000-0000-0000-0000-00000000000a', 'Cancelled Show', 'cancelled-show', now() + interval '30 days', 'Teatro Colon', 'CANCELLED'),
  ('05e00000-0000-0000-0000-000000000005', '05000000-0000-0000-0000-00000000000a', 'Archived Show', 'archived-show', now() + interval '30 days', 'Teatro Colon', 'ARCHIVED');

-- Ticket types on the PUBLISHED event: one of each kind the public
-- boundary must distinguish between.
insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('05c00000-0000-0000-0000-000000000001', '05000000-0000-0000-0000-00000000000a', '05e00000-0000-0000-0000-000000000001', 'General', 1500000, 'ARS', 100, 'PUBLIC', true),
  ('05c00000-0000-0000-0000-000000000002', '05000000-0000-0000-0000-00000000000a', '05e00000-0000-0000-0000-000000000001', 'Backstage Comp', 0, 'ARS', 10, 'HIDDEN', true),
  ('05c00000-0000-0000-0000-000000000003', '05000000-0000-0000-0000-00000000000a', '05e00000-0000-0000-0000-000000000001', 'Retired Tier', 1000000, 'ARS', 50, 'PUBLIC', false);

-- A PUBLIC, active, in-stock ticket type on the DRAFT event - proves
-- visibility is gated by the EVENT's status, not just the ticket type's
-- own flags.
insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('05c00000-0000-0000-0000-000000000004', '05000000-0000-0000-0000-00000000000a', '05e00000-0000-0000-0000-000000000002', 'Draft Event Ticket', 500000, 'ARS', 20, 'PUBLIC', true);

-- Now that a qualifying (PUBLIC/active/quantity>0) ticket type exists,
-- publish the event - exercising the same publish path RFC-004 already
-- validated, rather than smuggling a PUBLISHED row past the trigger.
update public.events set status = 'PUBLISHED'
  where id = '05e00000-0000-0000-0000-000000000001';

-- ---------------------------------------------------------------------------
-- anon: events visibility by status
-- ---------------------------------------------------------------------------
set local role anon;

select isnt_empty(
  $$ select 1 from public.events where id = '05e00000-0000-0000-0000-000000000001' $$,
  '01: anon can read a PUBLISHED event through the public boundary'
);

select is_empty(
  $$ select 1 from public.events where id = '05e00000-0000-0000-0000-000000000002' $$,
  '02: anon cannot read a DRAFT event'
);

select is_empty(
  $$ select 1 from public.events where id = '05e00000-0000-0000-0000-000000000003' $$,
  '03: anon cannot read a FINISHED event through normal public access'
);

select is_empty(
  $$ select 1 from public.events where id = '05e00000-0000-0000-0000-000000000004' $$,
  '04: anon cannot read a CANCELLED event'
);

select is_empty(
  $$ select 1 from public.events where id = '05e00000-0000-0000-0000-000000000005' $$,
  '05: anon cannot read an ARCHIVED event'
);

-- ---------------------------------------------------------------------------
-- anon: ticket_types visibility
-- ---------------------------------------------------------------------------
select isnt_empty(
  $$ select 1 from public.ticket_types where id = '05c00000-0000-0000-0000-000000000001' $$,
  '06: anon can read a PUBLIC active ticket type for a published event'
);

select is_empty(
  $$ select 1 from public.ticket_types where id = '05c00000-0000-0000-0000-000000000002' $$,
  '07: anon cannot read a HIDDEN ticket type'
);

select is_empty(
  $$ select 1 from public.ticket_types where id = '05c00000-0000-0000-0000-000000000003' $$,
  '08: anon cannot read an inactive ticket type'
);

select is_empty(
  $$ select 1 from public.ticket_types where id = '05c00000-0000-0000-0000-000000000004' $$,
  '09: a PUBLIC/active ticket type on a DRAFT event is not publicly visible - the event''s own status gates it'
);

-- ---------------------------------------------------------------------------
-- anon: organizations - row scoping AND column scoping
-- ---------------------------------------------------------------------------
select isnt_empty(
  $$ select 1 from public.organizations where id = '05000000-0000-0000-0000-00000000000a' $$,
  '10: anon can read the organization row for an org with a published event'
);

select is_empty(
  $$ select 1 from public.organizations where id = '05000000-0000-0000-0000-00000000000b' $$,
  '11: anon cannot read an organization with zero published events (no enumeration of private orgs)'
);

select isnt_empty(
  $$ select name, slug from public.organizations where id = '05000000-0000-0000-0000-00000000000a' $$,
  '12: anon can read organizations.name/slug (part of the public contract)'
);

select throws_ok(
  $$ select logo_url from public.organizations where id = '05000000-0000-0000-0000-00000000000a' $$,
  '42501',
  null,
  '13: anon cannot read organizations.logo_url - column-level privilege denies it even though the row is visible'
);

select throws_ok(
  $$ select status from public.organizations where id = '05000000-0000-0000-0000-00000000000a' $$,
  '42501',
  null,
  '14: anon cannot read organizations.status - not part of the public contract'
);

-- ---------------------------------------------------------------------------
-- anon: wrong organization/event slug combination, and no mutation access
-- ---------------------------------------------------------------------------
select is_empty(
  $$ select 1 from public.events
     where slug = 'published-show'
       and organization_id = '05000000-0000-0000-0000-00000000000b' $$,
  '15: a published event''s slug under the WRONG organization returns no public record'
);

select throws_ok(
  $$ insert into public.events (organization_id, name, slug, starts_at)
     values ('05000000-0000-0000-0000-00000000000a', 'Anon Event', 'anon-event', now() + interval '10 days') $$,
  '42501',
  null,
  '16: public access does not grant mutation privileges - anon cannot insert an event'
);

-- An UPDATE behaves differently from an INSERT under RLS (the same
-- asymmetry RFC-004 documented for authenticated cross-role UPDATEs):
-- `anon` DOES hold a table-level UPDATE grant (Supabase's default
-- privileges, same as SELECT/INSERT/DELETE - RLS is the only real gate),
-- and with zero `for update` policies naming `anon`, the row is simply
-- excluded from the update (0 rows affected), not rejected with an error.
-- `lives_ok` plus a follow-up authenticated read proves both halves: the
-- statement does not throw, AND it truthfully changed nothing.
select lives_ok(
  $$ update public.events set status = 'CANCELLED' where id = '05e00000-0000-0000-0000-000000000001' $$,
  '17: anon''s update attempt on a published event does not throw ...'
);

reset role;
set local role authenticated;
select set_config('request.jwt.claim.sub', 'f1000000-0000-0000-0000-000000000001', true);

select results_eq(
  $$ select status from public.events where id = '05e00000-0000-0000-0000-000000000001' $$,
  $$ values ('PUBLISHED'::public.event_status) $$,
  '18: ... but it also affected zero rows - the event is still PUBLISHED, not CANCELLED'
);

select * from finish();

rollback;
