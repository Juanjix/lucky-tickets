-- RFC-005: Public Event Page.
--
-- Adds the anonymous ("anon") read boundary the first buyer-facing page
-- needs, WITHOUT touching any RFC-002/RFC-003/RFC-004 migration and
-- without broadening the existing `to authenticated` organizer policies
-- at all (those are untouched - a member's own access is governed
-- exclusively by RFC-002's `events_select_member` /
-- `ticket_types_select_member` / `organizations_select_member`, unchanged).
--
-- No new table, column, or enum. `events` and `ticket_types` already carry
-- everything RFC-005 needs (`status`, `visibility`, `active`, `quantity`,
-- `sales_start_at`, `sales_end_at`); this migration only adds three new,
-- narrowly-scoped `for select ... to anon` RLS policies (Postgres OR's
-- permissive policies together, so these purely ADD visibility for
-- already-public data - they cannot take away or alter anything an
-- authenticated organizer can already see) plus one column-level privilege
-- narrowing on `organizations`.
--
-- Architecture note: the public route
-- (src/app/e/[organizationSlug]/[eventSlug]/page.tsx) reads through a
-- dedicated Supabase client (src/lib/supabase/public.ts) that never
-- forwards the visitor's session/cookies, so it always executes as `anon`
-- at the database - regardless of whether the visitor happens to be logged
-- in as a member of some other organization in the same browser. That
-- keeps "the public boundary" a single, crisp Postgres role to reason
-- about and test, rather than a mix of anon-or-authenticated depending on
-- browser state. It also means these new policies never need to consider
-- `authenticated` at all: an authenticated request to the public path
-- simply isn't made.
--
-- Security posture for each policy below is `security invoker` by
-- construction - these are plain RLS policies, not functions, so there is
-- no elevated-privilege mode to justify or avoid in the first place.

-- ---------------------------------------------------------------------------
-- events: anon may see events with status = 'PUBLISHED'. All other
-- persisted statuses (DRAFT/FINISHED/CANCELLED/ARCHIVED) remain invisible
-- to anon, exactly as RFC-005 "Public access rules" requires - a FINISHED
-- or CANCELLED event is not "published" in this predicate, so it is not
-- publicly readable through this policy (RFC-006+ may revisit whether a
-- FINISHED event should stay visible after the fact; RFC-005 does not).
-- ---------------------------------------------------------------------------
create policy events_select_public
  on public.events for select
  to anon
  using (status = 'PUBLISHED');

-- ---------------------------------------------------------------------------
-- ticket_types: anon may see only PUBLIC, active, positive-quantity ticket
-- types belonging to a currently PUBLISHED event - mirrors RFC-005's own
-- "Ticket Type public visibility" rule set exactly. Availability windows
-- (sales_start_at/sales_end_at) are deliberately NOT part of this
-- visibility predicate: a not-yet-on-sale or already-ended PUBLIC ticket
-- type should still be listed on the page (as "Sales start ..." / "Sales
-- ended" - see src/features/events/public/availability.ts), just not
-- purchasable. Only visibility/active/quantity/event-status gate whether a
-- row exists for the buyer at all.
-- ---------------------------------------------------------------------------
create policy ticket_types_select_public
  on public.ticket_types for select
  to anon
  using (
    visibility = 'PUBLIC'
    and active
    and quantity > 0
    and exists (
      select 1
      from public.events e
      where e.id = ticket_types.event_id
        and e.status = 'PUBLISHED'
    )
  );

-- ---------------------------------------------------------------------------
-- organizations: anon may see the organizer's public identity - and
-- nothing else. Unlike events/ticket_types above (where a row-level policy
-- is enough, because the public DTO mapper in application code is what
-- actually narrows which columns ever reach the page - see
-- src/features/events/public/queries.ts), `organizations` gets a genuine,
-- database-enforced COLUMN restriction too, per RFC-005's explicit
-- instruction to "expose only the minimum necessary data" rather than the
-- whole row. `logo_url`, `status`, and the timestamps are not part of the
-- public contract, and an application bug (a careless `.select("*")`)
-- should not be ABLE to leak them - not just be discouraged from it.
--
-- A real Supabase project's bootstrap privileges already grant `anon`
-- (and `authenticated`) table-wide access by default (the same mechanism
-- RFC-003 documented for function EXECUTE grants - see that migration's
-- header comment) - RLS is normally the only thing standing in front of
-- that. The explicit `revoke` below removes that blanket table-level
-- grant for `anon` specifically (never for `authenticated`, which keeps
-- its own full-column access for organization members, unchanged) before
-- re-granting only the columns the public contract needs, plus `id` -
-- the policy predicate itself reads `organizations.id`, so `anon` needs
-- column privilege on it to evaluate the policy at all, even though `id`
-- is never rendered on the public page.
-- ---------------------------------------------------------------------------
revoke select on public.organizations from anon;
grant select (id, name, slug, timezone, currency) on public.organizations to anon;

create policy organizations_select_public
  on public.organizations for select
  to anon
  using (
    exists (
      select 1
      from public.events e
      where e.organization_id = organizations.id
        and e.status = 'PUBLISHED'
    )
  );

-- No INSERT/UPDATE/DELETE policy is added for `anon` on any of the three
-- tables above, so `anon` gains read-only access here, full stop - even
-- though `anon` DOES hold table-level INSERT/UPDATE/DELETE grants (a real
-- Supabase project's default privileges apply the same "grant everything,
-- let RLS gate it" posture to every command, not just SELECT). With zero
-- matching policies for a given command, Postgres RLS defaults to deny,
-- but the SHAPE of that denial differs by command (verified empirically -
-- see rfc_005_public_event_access.test.sql "mutation" tests, and RFC-004's
-- migration header for the original discovery of this asymmetry): an
-- INSERT's `WITH CHECK` failing on every row throws (42501) because a
-- rejected new row has nowhere else to go, while an UPDATE's absent
-- `USING` clause just excludes the row from the update entirely (0 rows
-- affected, no error) - the same filtering semantics as an unmatched
-- WHERE clause. Either way, `anon` cannot actually change a row through
-- this path.
