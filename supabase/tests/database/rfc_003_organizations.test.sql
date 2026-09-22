-- RFC-003 database test suite (pgTAP): the `create_organization` RPC
-- introduced by supabase/migrations/20260921000000_rfc_003_organization_provisioning.sql.
--
-- This file intentionally does NOT re-verify RFC-002's tenant-isolation and
-- role-matrix behavior (see supabase/tests/database/rfc_002_security.test.sql,
-- 22 assertions, already covering that). It focuses on the new database
-- behavior RFC-003 introduces: atomic organization + OWNER provisioning,
-- the RLS-visibility subtlety that shaped its implementation (see the
-- migration's "Ordering note"), and — added after real `supabase test db`
-- caught what this project's local Postgres substitute originally missed —
-- the function's EXECUTE privilege grants themselves, asserted directly
-- via catalog introspection rather than only inferred from a call's
-- behavior. See docs/rfcs/RFC-003-auth-organizations.md "Security" for the
-- incident this section was added for: a real Supabase project's bootstrap
-- grants every new function a DIRECT execute entry to anon, separate from
-- (and not removed by revoking) PUBLIC's implicit one, which the original
-- version of this migration didn't revoke.
--
-- Run via the Supabase CLI once a local stack is available:
--   supabase test db

begin;

create extension if not exists pgtap with schema extensions;

select plan(14);

-- ---------------------------------------------------------------------------
-- Privilege configuration - the database-privilege layer, independent of
-- anything the function's own body does. These use pgTAP's
-- function_privs_are(), which reads pg_proc.proacl directly (the same
-- catalog inspected manually while diagnosing the real-Supabase failure),
-- rather than inferring privileges from whether a call raised an error.
-- No fixtures needed - this is pure catalog state, unaffected by data.
-- ---------------------------------------------------------------------------

select function_privs_are(
  'public', 'create_organization', array['text', 'text', 'text']::name[],
  'anon', array[]::name[],
  'anon has no privileges at all on create_organization (not EXECUTE, not anything else)'
);

select function_privs_are(
  'public', 'create_organization', array['text', 'text', 'text']::name[],
  'public', array[]::name[],
  'the PUBLIC pseudo-role has no privileges on create_organization (rules out the implicit-PUBLIC-grant path anon could otherwise inherit)'
);

select function_privs_are(
  'public', 'create_organization', array['text', 'text', 'text']::name[],
  'authenticated', array['EXECUTE']::name[],
  'authenticated is granted EXECUTE on create_organization'
);

-- ---------------------------------------------------------------------------
-- Fixtures
-- ---------------------------------------------------------------------------

insert into auth.users (id, email) values
  ('c1000000-0000-0000-0000-000000000001', 'creator-one@example.test'),
  ('c2000000-0000-0000-0000-000000000002', 'creator-two@example.test'),
  ('c3000000-0000-0000-0000-000000000003', 'bystander@example.test');

-- ---------------------------------------------------------------------------
-- Behavioral test: anon is refused at the privilege layer itself (42501,
-- "permission denied for function"), before the function body ever runs -
-- retained alongside the privilege-introspection tests above because it
-- proves the two layers agree, and because it's what a real PostgREST
-- request as anon would actually observe. This is deliberately a
-- DIFFERENT SQLSTATE from the next test below (28000): 42501 means the
-- privilege grant itself blocked the call (this test); 28000 (next test)
-- means the call was let in the door as `authenticated` and rejected by
-- the function's own internal check instead. Conflating those would hide
-- exactly the kind of privilege-grant regression this file was extended
-- to catch - see the file header.
-- ---------------------------------------------------------------------------
set local role anon;

select throws_ok(
  $$ select public.create_organization('Anon Org', 'anon-org') $$,
  '42501',
  null,
  'anon cannot execute create_organization (blocked at the privilege layer, never enters the function)'
);

reset role;

-- ---------------------------------------------------------------------------
-- Test: an authenticated caller with no resolvable auth.uid() (no JWT
-- "sub" claim set) IS let past the privilege grant (authenticated has
-- EXECUTE, asserted above) and is instead rejected by the function's own
-- internal check (SQLSTATE 28000) - the function-validation layer, not the
-- privilege layer. Not just RLS silently doing nothing, either: this is an
-- explicit `raise exception` in the function body. Three independent
-- layers, three independent tests: privilege grant (above), function
-- validation (this test), and RLS (exercised implicitly by every
-- successful call below, and explicitly in rfc_002_security.test.sql).
-- ---------------------------------------------------------------------------
set local role authenticated;
select set_config('request.jwt.claim.sub', '', true);

select throws_ok(
  $$ select public.create_organization('No Claims Org', 'no-claims-org') $$,
  '28000',
  'create_organization requires an authenticated user',
  'authenticated role without a JWT sub claim is rejected explicitly'
);

select is_empty(
  $$ select 1 from public.organizations where slug = 'no-claims-org' $$,
  'the rejected attempt left no organization row behind'
);

-- ---------------------------------------------------------------------------
-- Test: a real authenticated user creates an organization and becomes its
-- OWNER atomically, in a single RPC call.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000001', true);

select lives_ok(
  $$ select public.create_organization('Producciones Sur', 'producciones-sur') $$,
  'authenticated user can call create_organization successfully'
);

select isnt_empty(
  $$ select 1 from public.organizations where slug = 'producciones-sur' $$,
  'the organization row exists and is visible to its creator (SELECT RLS passes post-membership)'
);

select results_eq(
  $$ select role::text from public.organization_members m
     join public.organizations o on o.id = m.organization_id
     where o.slug = 'producciones-sur' and m.user_id = 'c1000000-0000-0000-0000-000000000001' $$,
  $$ values ('OWNER') $$,
  'the creator was made OWNER of the new organization, in the same call'
);

-- ---------------------------------------------------------------------------
-- Test: tenant isolation still holds for organizations created through the
-- RPC - an unrelated authenticated user cannot see it.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', 'c3000000-0000-0000-0000-000000000003', true);

select is_empty(
  $$ select 1 from public.organizations where slug = 'producciones-sur' $$,
  'a bystander user cannot see an organization created by create_organization for someone else'
);

-- ---------------------------------------------------------------------------
-- Test: slug collisions are resolved server-side with a numeric suffix,
-- rather than failing the whole operation.
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', 'c2000000-0000-0000-0000-000000000002', true);

select results_eq(
  $$ select slug from public.create_organization('Producciones Sur', 'producciones-sur') $$,
  $$ values ('producciones-sur-2') $$,
  'a slug collision is resolved by appending a numeric suffix instead of erroring'
);

select results_eq(
  $$ select role::text from public.organization_members m
     join public.organizations o on o.id = m.organization_id
     where o.slug = 'producciones-sur-2' and m.user_id = 'c2000000-0000-0000-0000-000000000002' $$,
  $$ values ('OWNER') $$,
  'the second creator was made OWNER of their own (suffixed) organization, not the first one'
);

-- ---------------------------------------------------------------------------
-- Test: a user can belong to more than one organization (RFC-003
-- "Multiple organizations" - the model is user -> organization_members ->
-- many organizations, never a single organization per user).
-- ---------------------------------------------------------------------------
select set_config('request.jwt.claim.sub', 'c1000000-0000-0000-0000-000000000001', true);

select lives_ok(
  $$ select public.create_organization('Prisma', 'prisma') $$,
  'the same user can create and own a second, independent organization'
);

select results_eq(
  $$ select count(*)::int from public.organization_members where user_id = 'c1000000-0000-0000-0000-000000000001' $$,
  $$ values (2) $$,
  'that user now has two OWNER memberships, one per organization, not a single-org relationship'
);

select * from finish();

rollback;
