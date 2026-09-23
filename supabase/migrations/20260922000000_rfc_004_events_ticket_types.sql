-- RFC-004: Events & Ticket Types.
--
-- RFC-002 already created `public.events` and `public.ticket_types` in
-- full, including every column RFC-004 needs (name, slug, venue_name,
-- venue_address, starts_at, ends_at, capacity, status; and unit_price_amount,
-- currency, quantity, visibility, sales_start_at/sales_end_at, sort_order,
-- active) and their RLS policies (`events_select_member`,
-- `events_insert_operator`, `events_update_operator`,
-- `ticket_types_select_member`, `ticket_types_insert_operator`,
-- `ticket_types_update_operator`, `ticket_types_delete_operator` — all
-- OWNER/ADMIN/PRODUCER-write, any-member-read, matching RFC-004's
-- permission model exactly). No new table and no new column is needed, and
-- none is added here. This migration adds only the two integrity
-- invariants RFC-004 introduces that a plain CHECK constraint cannot
-- express, because both span more than one row:
--
--   1. The sum of an event's ticket type inventory must not exceed the
--      event's capacity, when capacity is set.
--   2. An event cannot be marked PUBLISHED unless it has a venue and at
--      least one sellable (PUBLIC, active, positive-quantity) ticket type.
--
-- Both are implemented as triggers, not a generic workflow/state-machine
-- framework: each is a single, narrowly-scoped check, run as SECURITY
-- INVOKER (the same role performing the write already has SELECT access to
-- both tables via the existing RLS policies above, so no elevated
-- privilege is needed — see RFC-004's "Default to SECURITY INVOKER").
-- These are a second, database-level layer of defense in depth on top of
-- the application-level checks in `src/features/events/publish-rules.ts`
-- and the Server Actions that call it — matching the same
-- RLS-plus-application-authorization pattern established by RFC-002/RFC-003,
-- not a replacement for the application-level checks.

-- =============================================================================
-- INVARIANT 1: ticket type inventory must not exceed event capacity
-- =============================================================================
-- "Inventory" here means active ticket types only — a deactivated (soft-
-- removed) ticket type no longer counts against capacity. Capacity is
-- optional (`events.capacity` is nullable): when it's null, the organizer
-- hasn't set an overall cap, and this check does not apply.

create function public.check_event_ticket_capacity(p_event_id uuid)
returns void
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_capacity integer;
  v_allocated bigint;
begin
  select capacity into v_capacity from public.events where id = p_event_id;

  if v_capacity is null then
    return;
  end if;

  select coalesce(sum(quantity), 0) into v_allocated
  from public.ticket_types
  where event_id = p_event_id
    and active;

  if v_allocated > v_capacity then
    raise exception
      'ticket type inventory (%) exceeds event capacity (%) for event %',
      v_allocated, v_capacity, p_event_id
      using errcode = '23514'; -- check_violation - consistent with every other integrity error in this schema
  end if;
end;
$$;

comment on function public.check_event_ticket_capacity(uuid) is
  'Raises 23514 if the sum of active ticket_types.quantity for p_event_id exceeds events.capacity (when capacity is set). Shared by both triggers below so the same rule applies whichever side of the relationship changed.';

create function public.enforce_ticket_type_capacity()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  perform public.check_event_ticket_capacity(new.event_id);

  -- event_id is not expected to change in normal use, but if it ever does,
  -- the ticket type's old event must not be left over-allocated either.
  if tg_op = 'UPDATE' and old.event_id is distinct from new.event_id then
    perform public.check_event_ticket_capacity(old.event_id);
  end if;

  return new;
end;
$$;

create trigger ticket_types_capacity_check
  after insert or update of quantity, event_id, active on public.ticket_types
  for each row execute function public.enforce_ticket_type_capacity();

comment on trigger ticket_types_capacity_check on public.ticket_types is
  'Defense in depth for RFC-004 "Event capacity": re-validates total allocated inventory against events.capacity whenever a ticket type''s quantity, event, or active flag changes.';

create function public.enforce_event_capacity_change()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
begin
  if new.capacity is distinct from old.capacity then
    perform public.check_event_ticket_capacity(new.id);
  end if;

  return new;
end;
$$;

create trigger events_capacity_check
  after update of capacity on public.events
  for each row execute function public.enforce_event_capacity_change();

comment on trigger events_capacity_check on public.events is
  'Re-validates existing ticket type inventory whenever an event''s capacity is lowered (or set) below what is already allocated.';

-- =============================================================================
-- INVARIANT 2: publication invariants
-- =============================================================================
-- Mirrors (and backstops) the application-level checks in
-- `src/features/events/publish-rules.ts`. This does not replace that
-- module - it's the same "never trust the client, and don't even fully
-- trust the server action either" posture RFC-002/003 established for
-- authorization, applied here to a data invariant instead: even a raw
-- `update events set status = 'PUBLISHED' ...` that bypassed the Server
-- Action entirely is still rejected if the event isn't actually
-- publishable. Deliberately minimal: only the two structural invariants
-- that matter at the database level (a configured venue, and at least one
-- real, sellable ticket type) are enforced here. "Event name exists" and
-- "valid start date exists" are already guaranteed unconditionally by
-- existing RFC-002 NOT NULL/CHECK constraints on `events`, and "ticket
-- price/quantity is valid" is already guaranteed unconditionally by
-- existing RFC-002 CHECK constraints on `ticket_types` - none of those
-- need restating here.

create function public.enforce_event_publish_invariants()
returns trigger
language plpgsql
security invoker
set search_path = public, pg_temp
as $$
declare
  v_sellable_count bigint;
begin
  if new.status is distinct from 'PUBLISHED' then
    return new;
  end if;

  if new.venue_name is null or btrim(new.venue_name) = '' then
    raise exception 'cannot publish event %: venue is not configured', new.id
      using errcode = '23514';
  end if;

  select count(*) into v_sellable_count
  from public.ticket_types
  where event_id = new.id
    and visibility = 'PUBLIC'
    and active
    and quantity > 0;

  if v_sellable_count = 0 then
    raise exception 'cannot publish event %: no public ticket type is configured for sale', new.id
      using errcode = '23514';
  end if;

  return new;
end;
$$;

create trigger events_publish_invariants_check
  before insert or update of status on public.events
  for each row execute function public.enforce_event_publish_invariants();

comment on trigger events_publish_invariants_check on public.events is
  'Defense in depth for RFC-004 "Event publication": rejects any write that leaves status = PUBLISHED without a configured venue and at least one active, PUBLIC, positive-quantity ticket type - see src/features/events/publish-rules.ts for the full, richer set of invariants the application layer checks before ever attempting this update.';
