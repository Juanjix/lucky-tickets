-- RFC-003: Authentication & Organizations — organization provisioning.
--
-- RFC-002 already guarantees "every auth.users row has exactly one
-- public.profiles row" via the `handle_new_user()` trigger on `auth.users`
-- (see that migration's "PROFILES" section). RFC-003 does not touch that —
-- it is already correct and does not need a new migration.
--
-- What RFC-002 did NOT provide is a way to create an organization and its
-- first OWNER membership as a single atomic operation. Doing this as two
-- separate PostgREST calls from application code (`insert into
-- organizations`, then `insert into organization_members`) cannot be made
-- atomic from the client: each call is its own HTTP request/transaction,
-- so a failure of the second call (e.g. a transient network error) would
-- leave an organization with zero members — permanently unreachable by
-- anyone, since every RLS policy on every table gates on
-- `organization_members` and the bootstrap INSERT policy on
-- `organization_members` only fires for a *brand-new* organization with
-- zero existing members (see RFC-002's "organization_members_insert_bootstrap_owner").
--
-- The fix: a single `plpgsql` function that performs both inserts. A
-- function call is one statement in the calling transaction, so if the
-- second insert fails for any reason, the entire function's effects
-- (including the first insert) roll back — "organization without OWNER"
-- becomes impossible through this path, without needing a database
-- trigger, an application-level transaction manager, or two-phase commit.
--
-- This function is SECURITY INVOKER (the default — stated explicitly here
-- for clarity), not SECURITY DEFINER: it must run as the calling user so
-- that RFC-002's existing RLS policies (`organizations_insert_authenticated`,
-- `organization_members_insert_bootstrap_owner`) are what actually
-- authorize the two inserts. This function does not bypass RLS or add any
-- new authorization logic of its own — it only makes an already-legal
-- sequence of operations atomic. An unauthenticated caller (auth.uid() is
-- null) is rejected explicitly up front for a clear error message, though
-- the RLS policies alone would already block such a caller's inserts.
--
-- Ordering note (discovered while writing this migration's own pgTAP
-- coverage, not a hypothetical): the `organizations` INSERT cannot use
-- `RETURNING` here. PostgreSQL evaluates a statement's RETURNING output
-- against the table's SELECT policies, not just the INSERT policy's WITH
-- CHECK — and at the instant the organization is inserted, its creator is
-- not a member of it yet (that only becomes true after the second insert
-- below), so `organizations_select_member` would reject the RETURNING
-- projection and the whole statement would raise
-- "new row violates row-level security policy", even though the INSERT
-- itself is fully authorized by `organizations_insert_authenticated`. The
-- fix is to generate the id ourselves, insert without RETURNING, insert
-- the OWNER membership (which makes the creator a member), and only then
-- SELECT the row back — by which point `organizations_select_member`
-- passes normally. This is a consequence of RFC-002's RLS design, not a
-- defect in it: no policy is weakened or bypassed to make this work.

create function public.create_organization(
  p_name text,
  p_slug text,
  p_timezone text default 'America/Argentina/Buenos_Aires'
)
returns public.organizations
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_org public.organizations;
  v_org_id uuid := gen_random_uuid();
  v_slug text := p_slug;
  v_attempt int := 0;
  v_max_attempts constant int := 5;
begin
  if auth.uid() is null then
    raise exception 'create_organization requires an authenticated user'
      using errcode = '28000'; -- invalid_authorization_specification
  end if;

  if btrim(coalesce(p_name, '')) = '' then
    raise exception 'organization name must not be blank'
      using errcode = '22023'; -- invalid_parameter_value
  end if;

  -- Slug collisions are resolved server-side by appending a numeric suffix
  -- and retrying, rather than asking the caller to guess an available
  -- slug up front. Each failed attempt is caught in its own subtransaction
  -- (the implicit behavior of a plpgsql BEGIN/EXCEPTION block) so it does
  -- not poison the outer transaction. Bounded to v_max_attempts so a
  -- pathological input can't loop forever. No RETURNING here — see the
  -- ordering note above.
  loop
    v_attempt := v_attempt + 1;

    begin
      insert into public.organizations (id, name, slug, timezone)
      values (v_org_id, btrim(p_name), v_slug, coalesce(nullif(btrim(p_timezone), ''), 'America/Argentina/Buenos_Aires'));

      exit;
    exception
      when unique_violation then
        if v_attempt >= v_max_attempts then
          raise exception 'slug "%" is not available after % attempts', p_slug, v_max_attempts
            using errcode = '23505'; -- unique_violation, surfaced to the caller
        end if;

        v_slug := p_slug || '-' || (v_attempt + 1)::text;
    end;
  end loop;

  -- This relies on RFC-002's `organization_members_insert_bootstrap_owner`
  -- policy: it only permits the insert because v_org_id was just created
  -- in this same transaction and therefore has zero existing members.
  insert into public.organization_members (organization_id, user_id, role)
  values (v_org_id, auth.uid(), 'OWNER');

  -- Now that the caller is a member, `organizations_select_member` passes
  -- and this SELECT (and its use as this function's RETURNING-equivalent)
  -- succeeds normally.
  select * into v_org from public.organizations where id = v_org_id;

  return v_org;
end;
$$;

comment on function public.create_organization(text, text, text) is
  'Atomically creates an organization and makes the calling user its OWNER. SECURITY INVOKER: runs under the caller''s RLS, does not bypass it. Retries the slug with a numeric suffix on collision, up to 5 attempts. See RFC-003 "Organization creation".';

-- PostgREST exposes this as POST /rest/v1/rpc/create_organization to any
-- authenticated caller. anon is intentionally NOT granted execute: creating
-- an organization requires a signed-in user (enforced twice over — by this
-- privilege revocation, and again inside the function body via the
-- auth.uid() check, as defense in depth - see the note above that comment).
--
-- Both REVOKEs below are necessary, and for different reasons - this was
-- corrected after real `supabase test db` caught what this sandbox's local
-- Postgres substitute could not (see docs/rfcs/RFC-003-auth-organizations.md
-- "Security" for the full incident writeup):
--
-- 1. `... FROM PUBLIC`: PostgreSQL grants EXECUTE on every newly created
--    function to PUBLIC by default. Every role, including anon, is
--    implicitly a member of PUBLIC, so without this, anon could call this
--    function via that implicit membership alone.
--
-- 2. `... FROM anon`, separately: a real Supabase project's bootstrap
--    (`roles.sql`, applied before any project migration runs) already
--    holds an `ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
--    GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role`
--    style default. Because migrations run as `postgres`, that default
--    privilege grants `anon` a DIRECT execute entry on this function at
--    creation time — not one it holds through PUBLIC. Revoking from PUBLIC
--    does not touch a direct, separately-named grant to `anon`; only
--    revoking from `anon` explicitly does. This is exactly why the local
--    Postgres substitute used earlier in this project (a plain `apt`
--    install with no Supabase-specific bootstrap) did not catch this: it
--    never had that default privilege in the first place, so `REVOKE ...
--    FROM PUBLIC` alone looked sufficient there. Reproduced directly by
--    replaying Supabase's default-privilege statement against that
--    substitute and confirming `anon` retained EXECUTE until this REVOKE
--    was added - see the pgTAP tests below, which now assert both roles'
--    privileges directly via `has_function_privilege()` rather than only
--    inferring them from a call's behavior.
revoke execute on function public.create_organization(text, text, text) from public;
revoke execute on function public.create_organization(text, text, text) from anon;
grant execute on function public.create_organization(text, text, text) to authenticated;
