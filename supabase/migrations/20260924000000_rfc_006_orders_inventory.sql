-- RFC-006: Orders & Inventory.
--
-- Adds Lucky Ticket's first transactional buyer flow: anonymous checkout
-- creates a PENDING_PAYMENT order with a concurrency-safe inventory
-- reservation (a `ticket_holds` row per line), backed by a secure,
-- single-use checkout access token. There is NO Mercado Pago integration
-- here and NO PENDING_PAYMENT -> PAID transition - both belong to RFC-007.
--
-- This migration does NOT redesign any RFC-002 table. `orders`,
-- `order_items`, `ticket_holds`, `customers`, and `ticket_types` already
-- have every column this flow needs (see RFC-002's migration header and
-- docs/database.md) except one: `orders` gets a single new nullable
-- column, `checkout_token_hash`, because RFC-002 never anticipated an
-- anonymous buyer needing to prove ownership of an order without an
-- account. No other schema change was necessary; see
-- docs/rfcs/RFC-006-orders-inventory.md "Inspect existing architecture
-- first" for the full inventory of what was checked before writing this
-- file.
--
-- =============================================================================
-- WHY THREE NEW SECURITY DEFINER FUNCTIONS, NOT NEW RLS POLICIES
-- =============================================================================
-- RFC-002 gives `orders`/`order_items`/`ticket_holds`/`customers` zero
-- INSERT/UPDATE policies for ANY role, and their only SELECT policies are
-- `to authenticated` or organizer roles. Anonymous checkout must create
-- rows in all four tables. Two designs were considered:
--
--   1. Add `to anon` INSERT/SELECT policies scoped as tightly as possible
--      (e.g. "anon can insert an order if ..."). Rejected: RLS policies
--      are evaluated per-ROW, not per-TRANSACTION, so they cannot express
--      "lock this ticket_types row, recompute availability, and only
--      then allow the order/order_items/ticket_holds inserts as one
--      atomic unit." A buyer could always race two separate PostgREST
--      requests against separate policies and reintroduce the exact
--      overselling race RFC-006 exists to prevent (RFC-006 section 3.2).
--
--   2. A single SECURITY DEFINER function that performs the entire
--      validate-lock-insert sequence as one Postgres transaction,
--      re-validating every tenant/commerce invariant itself instead of
--      relying on RLS at all for its internal writes. Chosen.
--
-- This is a deliberate, justified use of SECURITY DEFINER (RFC-006
-- section 29's checklist, addressed point by point):
--   - explicit safe search_path: every function below sets
--     `search_path = public, pg_temp` - never relies on the caller's
--     search_path, so it cannot be tricked into resolving a
--     caller-controlled function/table of the same unqualified name.
--   - fully validates tenant boundaries: `create_order_with_hold` re-reads
--     organization/event/ticket_type by slug/id and re-checks every
--     organization_id/event_id relationship itself - it never trusts a
--     ticket_type_id belongs to the requested event/organization just
--     because the caller said so (RFC-006 section 47).
--   - validates event/ticket relationships: see the per-line validation
--     loop below (status, visibility, active, sales window, currency).
--   - no dynamic SQL: every statement is a static, parameterized query;
--     nothing here is built via `execute format(...)`.
--   - narrow interface: `create_order_with_hold` takes only buyer-intent
--     scalars/JSON (slugs, a JSON items array, buyer name/email/phone, a
--     pre-hashed checkout token) - never an organization/event/ticket
--     type UUID directly, and never a price. `get_checkout_order` takes
--     only an order id and a token hash.
--   - returns only required fields: both functions RETURN TABLE with an
--     explicit narrow column list, never `select *` or a whole row type -
--     no customer PII, no checkout_token_hash, no internal audit columns.
--   - does not trust caller-supplied internal IDs unnecessarily: the one
--     internal ID the caller does supply (`ticketTypeId`, chosen by the
--     buyer from the public event page) is re-validated against the
--     resolved organization_id/event_id before ever being used for a
--     lock or a write - see "3. Validate + lock" below.
--
-- Every EXECUTE privilege below is asserted explicitly, never left to
-- Supabase's default per-function grant to anon/authenticated (the exact
-- issue RFC-003 discovered and RFC-005 re-confirmed: `revoke ... from
-- public` alone does not remove a separately-held direct grant to `anon`).
-- pgTAP tests in rfc_006_orders_inventory.test.sql assert the resulting
-- privileges directly via `function_privs_are()`, not by inference from a
-- call's behavior.
--
-- =============================================================================
-- CONCURRENCY STRATEGY (see docs/rfcs/RFC-006-orders-inventory.md
-- "Concurrency strategy" for the full writeup and diagrams)
-- =============================================================================
-- `create_order_with_hold` takes `select ... for update` row locks on the
-- specific `ticket_types` rows a checkout touches, in ASCENDING id order
-- (`order by (value->>'ticketTypeId')::uuid`), before recomputing
-- availability. Two concurrent calls that both touch ticket type X:
--   - the second call's `for update` blocks until the first call's
--     transaction commits or rolls back (Postgres's normal row-lock
--     semantics - no advisory lock or extra mechanism needed);
--   - once unblocked, the second call recomputes availability from
--     scratch (fresh SELECTs against order_items/ticket_holds, executed
--     AFTER acquiring the lock) - so it always sees the first call's
--     committed reservation, never a stale read;
--   - if the first call already consumed the only remaining unit, the
--     second call's own availability check fails and the whole function
--     raises an exception, which rolls back everything that function call
--     had done (order/order_items/ticket_holds are only inserted AFTER
--     every line in the cart validates - see "6. Materialize" below), so
--     a rejected checkout leaves behind zero partial rows.
--
-- Locking every ticket type in the SAME deterministic order (ascending
-- id) regardless of the order the buyer's cart lists them in is what
-- prevents a classic multi-resource deadlock: if Buyer A's cart is
-- [General, VIP] and Buyer B's cart is [VIP, General], both transactions
-- still attempt to lock the lower-id ticket type first, so one of them
-- always succeeds in acquiring it before the other tries - neither can
-- ever be stuck holding one lock while waiting on a lock the other
-- already holds and won't release (the textbook lock-ordering deadlock
-- prevention rule). See "Deadlock diagram" in the RFC document and
-- `scripts/rfc-006-concurrency-test.sh` for an executable proof (pgTAP
-- runs in one session and cannot demonstrate real concurrency).
--
-- =============================================================================
-- INVENTORY MODEL (RFC-006 section 7)
-- =============================================================================
-- Available inventory for a ticket type is never a stored counter - it is
-- derived, at the moment it's needed, as:
--
--   ticket_types.quantity
--     - SUM(order_items.quantity) for PAID orders on this ticket type
--     - SUM(ticket_holds.quantity) for PENDING_PAYMENT orders on this
--       ticket type, WHERE ticket_holds.expires_at > now()
--
-- The PAID term does nothing yet (RFC-006 never creates a PAID order) but
-- is included now because RFC-007 must be able to introduce PAID orders
-- without changing this formula - see RFC-007 handoff in the RFC
-- document. The PENDING_PAYMENT term automatically excludes an EXPIRED
-- hold (`expires_at > now()`) with no dependency on `expire_pending_orders()`
-- ever having run (RFC-006 sections 10/44: "cleanup is not inventory
-- correctness"). It also automatically stops counting a hold the moment
-- its order is no longer PENDING_PAYMENT (e.g. a future PAID transition),
-- because the join filters on `o.status = 'PENDING_PAYMENT'` - so RFC-007
-- does not need to delete or otherwise touch a paid order's hold row for
-- this formula to stay correct; the PAID order's inventory is instead
-- accounted for through the first (order_items) term.
--
-- The identical expression (duplicated deliberately, not factored into a
-- shared helper function - see the comment on
-- `get_public_ticket_availability` below for why) appears in three
-- places: the per-line lock/validate loop in `create_order_with_hold`,
-- and `get_public_ticket_availability` (the public SOLD_OUT signal for
-- RFC-005's page). Keep all three in sync if this formula ever changes.

-- =============================================================================
-- SCHEMA CHANGE: orders.checkout_token_hash
-- =============================================================================
-- Stores only a SHA-256 hash of a cryptographically random token generated
-- in trusted Next.js server code (RFC-006 section 25: "Prefer generating
-- the token in trusted server-side code ... using a cryptographically
-- secure random generator"). The raw token is never sent to, computed by,
-- or stored in Postgres - see src/lib/checkout/token.ts. Nullable because
-- not every conceivable future order-creation path (e.g. a later
-- staff/comp-ticket flow) need go through checkout token issuance; a
-- unique constraint still guards against two orders ever sharing a hash
-- (which would let one buyer's token authorize a second order).
alter table public.orders
  add column checkout_token_hash text;

alter table public.orders
  add constraint orders_checkout_token_hash_key unique (checkout_token_hash);

comment on column public.orders.checkout_token_hash is
  'SHA-256 hex digest of the anonymous buyer''s checkout access token (RFC-006). The raw token is never persisted - see get_checkout_order() below and src/lib/checkout/token.ts. NULL for any order not created through the public checkout RPC.';

-- =============================================================================
-- create_order_with_hold: the atomic checkout transaction
-- =============================================================================
-- Every input is buyer INTENT ONLY (organization/event slugs, a
-- {ticketTypeId, quantity}[] cart, buyer name/email/phone, and a
-- pre-computed checkout token hash) - never a price, a subtotal, a total,
-- an organization/event id, an expiration, or an order status (RFC-006
-- section 3.1). This function alone resolves and validates every
-- authoritative value.
create function public.create_order_with_hold(
  p_organization_slug text,
  p_event_slug text,
  p_items jsonb,
  p_buyer_name text,
  p_buyer_email text,
  p_buyer_phone text,
  p_checkout_token_hash text
)
returns table (
  order_id uuid,
  order_status text,
  expires_at timestamptz,
  currency text,
  subtotal_amount bigint,
  total_amount bigint,
  items jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  -- Keep these two in sync with src/lib/checkout/constants.ts
  -- (CHECKOUT_HOLD_MINUTES, MAX_TICKETS_PER_ORDER) - see RFC-006 sections
  -- 9 and 16. Centralizing "the number 10 minutes"/"the number 10
  -- tickets" in exactly one place per layer (one TypeScript constant, one
  -- SQL constant here) is the closest this split client/database
  -- architecture can get to a single source of truth; a mismatch would
  -- only ever make the database's limit the effective (stricter or
  -- looser) one, never silently bypassed, since the database is what
  -- actually enforces it.
  v_hold_minutes constant int := 10;
  v_max_tickets_per_order constant int := 10;
  v_max_distinct_lines constant int := 20;

  v_org_id uuid;
  v_org_currency char(3);
  v_event_id uuid;
  v_event_status public.event_status;

  v_item jsonb;
  v_ticket_type_id uuid;
  v_quantity int;
  v_ticket_type public.ticket_types%rowtype;
  v_committed bigint;
  v_held bigint;
  v_available bigint;
  v_line_subtotal bigint;
  v_subtotal bigint := 0;
  v_validated_lines jsonb := '[]'::jsonb;
  v_result_items jsonb := '[]'::jsonb;

  v_seen_ticket_type_ids uuid[] := '{}';
  v_total_quantity int := 0;

  v_customer_id uuid;
  v_order_id uuid := gen_random_uuid();
  v_order_number text;
  v_expires_at timestamptz;
  v_attempt int := 0;
  v_max_attempts constant int := 5;
begin
  -- ---------------------------------------------------------------------
  -- 0. Structural input validation. This function is reachable directly
  -- via PostgREST by `anon` (see grants below) - EVERY invariant here is
  -- re-checked independently of whatever the Next.js Zod schema already
  -- validated, because a malicious caller can skip that schema entirely
  -- and call this RPC by hand (RFC-006 section 17).
  -- ---------------------------------------------------------------------
  if btrim(coalesce(p_organization_slug, '')) = '' or btrim(coalesce(p_event_slug, '')) = '' then
    raise exception 'organization/event slug required' using errcode = 'LT001';
  end if;

  if btrim(coalesce(p_buyer_name, '')) = '' or btrim(coalesce(p_buyer_email, '')) = '' then
    raise exception 'buyer name and email are required' using errcode = '22023';
  end if;

  if btrim(coalesce(p_checkout_token_hash, '')) = '' then
    raise exception 'checkout token hash is required' using errcode = '22023';
  end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'checkout requires at least one ticket line' using errcode = 'LT006';
  end if;

  if jsonb_array_length(p_items) > v_max_distinct_lines then
    raise exception 'too many distinct ticket lines' using errcode = 'LT009';
  end if;

  -- ---------------------------------------------------------------------
  -- 1. Resolve organization + event. Both "does not exist" and "exists
  -- but is not PUBLISHED" raise the SAME error (LT001/EVENT_NOT_AVAILABLE)
  -- - mirroring RFC-005's getPublicEvent uniform not-found boundary, so
  -- this RPC never lets a caller distinguish a private event from a
  -- nonexistent one (RFC-006 section 17, RFC-005 precedent).
  -- ---------------------------------------------------------------------
  select o.id, o.currency
    into v_org_id, v_org_currency
    from public.organizations o
    where o.slug = p_organization_slug;

  if v_org_id is null then
    raise exception 'event not available' using errcode = 'LT001';
  end if;

  select e.id, e.status
    into v_event_id, v_event_status
    from public.events e
    where e.organization_id = v_org_id
      and e.slug = p_event_slug;

  if v_event_id is null then
    raise exception 'event not available' using errcode = 'LT001';
  end if;

  if v_event_status <> 'PUBLISHED' then
    raise exception 'event not available' using errcode = 'LT001';
  end if;

  -- ---------------------------------------------------------------------
  -- 2. Shape-validate every line and reject duplicate ticket types up
  -- front, before taking any lock (cheap fail-fast pass).
  -- ---------------------------------------------------------------------
  for v_item in select value from jsonb_array_elements(p_items) as value
  loop
    if v_item ->> 'ticketTypeId' is null or v_item ->> 'quantity' is null then
      raise exception 'malformed checkout line' using errcode = 'LT006';
    end if;

    begin
      v_ticket_type_id := (v_item ->> 'ticketTypeId')::uuid;
    exception when invalid_text_representation then
      raise exception 'ticket type not available' using errcode = 'LT002';
    end;

    if v_ticket_type_id = any (v_seen_ticket_type_ids) then
      raise exception 'duplicate ticket type in checkout request' using errcode = 'LT006';
    end if;
    v_seen_ticket_type_ids := array_append(v_seen_ticket_type_ids, v_ticket_type_id);

    begin
      v_quantity := (v_item ->> 'quantity')::int;
    exception when others then
      raise exception 'invalid quantity' using errcode = 'LT006';
    end;

    if v_quantity is null or v_quantity <= 0 then
      raise exception 'quantity must be a positive integer' using errcode = 'LT006';
    end if;

    v_total_quantity := v_total_quantity + v_quantity;
  end loop;

  if v_total_quantity > v_max_tickets_per_order then
    raise exception 'checkout limit exceeded' using errcode = 'LT009';
  end if;

  -- ---------------------------------------------------------------------
  -- 3. Validate + lock every ticket type, in DETERMINISTIC ASCENDING ID
  -- ORDER regardless of the order the cart lists them in (RFC-006
  -- sections 12/13/60 - see the migration header's "Concurrency
  -- strategy" for why this specific ordering prevents deadlocks between
  -- overlapping multi-ticket carts). Every check below is a re-validation
  -- against freshly-locked data, never a value trusted from the caller or
  -- from the shape-only pass above.
  -- ---------------------------------------------------------------------
  for v_item in
    select value
      from jsonb_array_elements(p_items) as value
      order by (value ->> 'ticketTypeId')::uuid
  loop
    v_ticket_type_id := (v_item ->> 'ticketTypeId')::uuid;
    v_quantity := (v_item ->> 'quantity')::int;

    select tt.*
      into v_ticket_type
      from public.ticket_types tt
      where tt.id = v_ticket_type_id
        and tt.organization_id = v_org_id
        and tt.event_id = v_event_id
      for update;

    if not found then
      raise exception 'ticket type not available' using errcode = 'LT002';
    end if;

    if not v_ticket_type.active or v_ticket_type.visibility <> 'PUBLIC' then
      raise exception 'ticket type not available' using errcode = 'LT002';
    end if;

    if v_ticket_type.currency <> v_org_currency then
      -- Not currently reachable through the dashboard (createTicketTypeAction
      -- always writes organization.currency - see src/features/events/actions.ts),
      -- but checked anyway per RFC-006 section 17 ("requested ticket types
      -- use the expected event/organization currency") rather than assumed.
      raise exception 'ticket type not available' using errcode = 'LT002';
    end if;

    if v_ticket_type.sales_start_at is not null and v_ticket_type.sales_start_at > now() then
      raise exception 'ticket sales have not started' using errcode = 'LT003';
    end if;

    if v_ticket_type.sales_end_at is not null and v_ticket_type.sales_end_at <= now() then
      raise exception 'ticket sales have ended' using errcode = 'LT004';
    end if;

    if v_quantity > v_ticket_type.max_per_order then
      raise exception 'checkout limit exceeded' using errcode = 'LT009';
    end if;

    select coalesce(sum(oi.quantity), 0)
      into v_committed
      from public.order_items oi
      join public.orders o
        on o.organization_id = oi.organization_id
       and o.id = oi.order_id
      where oi.organization_id = v_org_id
        and oi.ticket_type_id = v_ticket_type.id
        and o.status = 'PAID';

    select coalesce(sum(h.quantity), 0)
      into v_held
      from public.ticket_holds h
      join public.orders o
        on o.organization_id = h.organization_id
       and o.id = h.order_id
      where h.organization_id = v_org_id
        and h.ticket_type_id = v_ticket_type.id
        and o.status = 'PENDING_PAYMENT'
        and h.expires_at > now();

    v_available := v_ticket_type.quantity::bigint - v_committed - v_held;

    if v_quantity > v_available then
      raise exception 'insufficient inventory for %', v_ticket_type.name using errcode = 'LT005';
    end if;

    v_line_subtotal := v_ticket_type.unit_price_amount * v_quantity;
    v_subtotal := v_subtotal + v_line_subtotal;

    v_validated_lines := v_validated_lines || jsonb_build_object(
      'ticketTypeId', v_ticket_type.id,
      'name', v_ticket_type.name,
      'quantity', v_quantity,
      'unitPriceAmount', v_ticket_type.unit_price_amount,
      'lineTotalAmount', v_line_subtotal
    );
  end loop;

  -- ---------------------------------------------------------------------
  -- 4. Resolve/create the buyer's customer record, strictly scoped to
  -- this organization (RFC-006 section 21). Reuses RFC-002's existing
  -- `customers_org_normalized_email_key` unique constraint - an
  -- organization-scoped conflict target, so this can never resolve to
  -- (let alone create a link to) another organization's customer row.
  -- ---------------------------------------------------------------------
  insert into public.customers (organization_id, email, name, last_seen_at)
  values (v_org_id, p_buyer_email, nullif(btrim(p_buyer_name), ''), now())
  on conflict (organization_id, normalized_email)
  do update set
    last_seen_at = now(),
    name = coalesce(excluded.name, public.customers.name)
  returning id into v_customer_id;

  -- ---------------------------------------------------------------------
  -- 5. Create the order. `expires_at` is generated HERE, server-side,
  -- from `v_hold_minutes` - the browser never supplies or influences it
  -- (RFC-006 section 9). `order_number` collisions are retried with the
  -- same bounded-attempts pattern `create_organization` uses for slugs
  -- (RFC-003 migration).
  -- ---------------------------------------------------------------------
  v_expires_at := now() + make_interval(mins => v_hold_minutes);

  loop
    v_attempt := v_attempt + 1;
    v_order_number := to_char(now(), 'YYYYMMDD') || '-' ||
      upper(substr(replace(gen_random_uuid()::text, '-', ''), 1, 8));

    begin
      insert into public.orders (
        id, organization_id, event_id, customer_id, order_number,
        buyer_name, buyer_email, buyer_phone, currency,
        subtotal_amount, service_fee_amount, total_amount,
        status, expires_at, checkout_token_hash
      ) values (
        v_order_id, v_org_id, v_event_id, v_customer_id, v_order_number,
        btrim(p_buyer_name), lower(btrim(p_buyer_email)), nullif(btrim(p_buyer_phone), ''),
        v_org_currency,
        v_subtotal, 0, v_subtotal,
        'PENDING_PAYMENT', v_expires_at, p_checkout_token_hash
      );

      exit;
    exception when unique_violation then
      if v_attempt >= v_max_attempts then
        raise exception 'could not allocate an order number, please try again' using errcode = '23505';
      end if;
    end;
  end loop;

  -- ---------------------------------------------------------------------
  -- 6. Materialize order_items + ticket_holds from the lines validated
  -- (and locked) in step 3. Nothing here re-derives price or quantity -
  -- every value was already computed under lock, above.
  -- ---------------------------------------------------------------------
  for v_item in select value from jsonb_array_elements(v_validated_lines) as value
  loop
    insert into public.order_items (
      organization_id, order_id, ticket_type_id, name_snapshot,
      unit_price_amount, quantity, subtotal_amount
    ) values (
      v_org_id, v_order_id, (v_item ->> 'ticketTypeId')::uuid, v_item ->> 'name',
      (v_item ->> 'unitPriceAmount')::bigint, (v_item ->> 'quantity')::int, (v_item ->> 'lineTotalAmount')::bigint
    );

    insert into public.ticket_holds (
      organization_id, event_id, ticket_type_id, order_id, quantity, expires_at
    ) values (
      v_org_id, v_event_id, (v_item ->> 'ticketTypeId')::uuid, v_order_id, (v_item ->> 'quantity')::int, v_expires_at
    );

    v_result_items := v_result_items || jsonb_build_object(
      'ticketTypeId', v_item ->> 'ticketTypeId',
      'name', v_item ->> 'name',
      'quantity', (v_item ->> 'quantity')::int,
      'unitPriceAmount', (v_item ->> 'unitPriceAmount')::bigint,
      'lineTotalAmount', (v_item ->> 'lineTotalAmount')::bigint
    );
  end loop;

  return query
    select v_order_id, 'PENDING_PAYMENT'::text, v_expires_at, v_org_currency::text, v_subtotal, v_subtotal, v_result_items;
end;
$$;

comment on function public.create_order_with_hold(text, text, jsonb, text, text, text, text) is
  'RFC-006 atomic checkout transaction. SECURITY DEFINER - see the migration header for the full justification. Locks every referenced ticket_types row (ascending id order) before recomputing availability, so a passing check and the insert it protects always happen under the same lock. Raises a stable LTxxx-coded exception (mapped to a domain error by src/features/checkout/errors.ts) on any invariant violation, rolling back everything this call did - never leaves a partial order/items/hold behind.';

revoke all on function public.create_order_with_hold(text, text, jsonb, text, text, text, text) from public;
revoke all on function public.create_order_with_hold(text, text, jsonb, text, text, text, text) from anon;
revoke all on function public.create_order_with_hold(text, text, jsonb, text, text, text, text) from authenticated;
grant execute on function public.create_order_with_hold(text, text, jsonb, text, text, text, text) to anon, authenticated;

-- =============================================================================
-- get_checkout_order: the ONLY way to read back a checkout, by design
-- =============================================================================
-- RFC-006 section 23: an order UUID alone must never be sufficient
-- authorization. There is deliberately no `to anon` SELECT policy on
-- `orders` of the form "id = ...", however narrow - that would let anyone
-- who merely guesses or observes an order id read it. This function is
-- the entire public read boundary for a checkout: it requires BOTH the
-- order id AND a token whose SHA-256 hash matches what was stored at
-- creation time (RFC-006 sections 24/27). An invalid token and a
-- nonexistent order id produce the exact same error (LT008 /
-- INVALID_CHECKOUT_TOKEN) - this function never confirms an order id
-- exists on its own.
create function public.get_checkout_order(
  p_order_id uuid,
  p_checkout_token_hash text
)
returns table (
  order_id uuid,
  order_status text,
  expires_at timestamptz,
  currency text,
  subtotal_amount bigint,
  total_amount bigint,
  event_name text,
  event_starts_at timestamptz,
  event_venue_name text,
  organization_name text,
  organization_timezone text,
  items jsonb
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
begin
  if p_order_id is null or btrim(coalesce(p_checkout_token_hash, '')) = '' then
    raise exception 'invalid checkout token' using errcode = 'LT008';
  end if;

  select o.*
    into v_order
    from public.orders o
    where o.id = p_order_id
      and o.checkout_token_hash = p_checkout_token_hash;

  if not found then
    raise exception 'invalid checkout token' using errcode = 'LT008';
  end if;

  return query
    select
      v_order.id,
      -- Report EXPIRED the instant expires_at has passed, even if the
      -- persisted status column still says PENDING_PAYMENT because
      -- expire_pending_orders() has not run yet - "cleanup is not
      -- inventory correctness" (RFC-006 section 44) applies equally to
      -- what the buyer is TOLD, not just to what inventory counts.
      case
        when v_order.status = 'PENDING_PAYMENT' and v_order.expires_at <= now() then 'EXPIRED'
        else v_order.status::text
      end,
      v_order.expires_at,
      v_order.currency::text,
      v_order.subtotal_amount,
      v_order.total_amount,
      e.name,
      e.starts_at,
      e.venue_name,
      org.name,
      org.timezone,
      coalesce(
        (select jsonb_agg(jsonb_build_object(
          'ticketTypeId', oi.ticket_type_id,
          'name', oi.name_snapshot,
          'quantity', oi.quantity,
          'unitPriceAmount', oi.unit_price_amount,
          'lineTotalAmount', oi.subtotal_amount
        ) order by oi.created_at)
        from public.order_items oi
        where oi.organization_id = v_order.organization_id
          and oi.order_id = v_order.id),
        '[]'::jsonb
      )
    from public.events e
    join public.organizations org on org.id = v_order.organization_id
    where e.organization_id = v_order.organization_id
      and e.id = v_order.event_id;
end;
$$;

comment on function public.get_checkout_order(uuid, text) is
  'RFC-006 narrow checkout read boundary. Requires BOTH the order id and a matching checkout_token_hash - an order id alone authorizes nothing. Never returns buyer_name/buyer_email/checkout_token_hash or any other customer/internal field beyond what the checkout confirmation page needs to render.';

revoke all on function public.get_checkout_order(uuid, text) from public;
revoke all on function public.get_checkout_order(uuid, text) from anon;
revoke all on function public.get_checkout_order(uuid, text) from authenticated;
grant execute on function public.get_checkout_order(uuid, text) to anon, authenticated;

-- =============================================================================
-- get_public_ticket_availability: authoritative SOLD_OUT signal for RFC-005
-- =============================================================================
-- RFC-005's public event page can already see a ticket type's row (via
-- `ticket_types_select_public`), but `anon` has zero SELECT access to
-- `order_items`/`ticket_holds`/`orders` - and must not gain any, even
-- narrowly, per RFC-006 section 46. This function is the only sanctioned
-- way the public page learns whether a ticket type is sold out, and it
-- deliberately returns ONLY a boolean per ticket type (RFC-006 section
-- 38: "isSoldOut may be preferable to availableQuantity") - never the
-- underlying counts, never a hold record, never a customer or order id.
--
-- The availability expression here is intentionally a literal copy of
-- the one inside create_order_with_hold's per-line validation (see the
-- migration header's "Inventory model" section), not a call to a shared
-- helper: a shared SECURITY DEFINER helper callable independently would
-- need its OWN privilege grants decided, and granting anon direct
-- execute on a function that returns the raw available count (rather
-- than just a boolean) would leak more than RFC-006 section 38 wants
-- exposed. Duplicating ~10 lines of SQL, with an explicit comment tying
-- the two together, was judged the simpler and more obviously-safe
-- option. `language sql stable` (not `plpgsql`) because it is one
-- declarative query with no branching/looping state to manage.
create function public.get_public_ticket_availability(p_event_id uuid)
returns table (ticket_type_id uuid, is_sold_out boolean)
language sql
security definer
stable
set search_path = public, pg_temp
as $$
  select
    tt.id,
    (
      tt.quantity::bigint
      - coalesce((
          select sum(oi.quantity)
          from public.order_items oi
          join public.orders o
            on o.organization_id = oi.organization_id
           and o.id = oi.order_id
          where oi.ticket_type_id = tt.id
            and o.status = 'PAID'
        ), 0)
      - coalesce((
          select sum(h.quantity)
          from public.ticket_holds h
          join public.orders o
            on o.organization_id = h.organization_id
           and o.id = h.order_id
          where h.ticket_type_id = tt.id
            and o.status = 'PENDING_PAYMENT'
            and h.expires_at > now()
        ), 0)
    ) <= 0 as is_sold_out
  from public.ticket_types tt
  where tt.event_id = p_event_id
    and tt.visibility = 'PUBLIC'
    and tt.active
    and exists (
      select 1 from public.events e
      where e.id = tt.event_id and e.status = 'PUBLISHED'
    );
$$;

comment on function public.get_public_ticket_availability(uuid) is
  'RFC-006 authoritative SOLD_OUT signal for the public event page. Returns only a boolean per already-publicly-visible ticket type - never a raw count, never a hold/order/customer row. Its availability expression must stay in sync with create_order_with_hold''s per-line check (see this migration''s header comment).';

revoke all on function public.get_public_ticket_availability(uuid) from public;
revoke all on function public.get_public_ticket_availability(uuid) from anon;
revoke all on function public.get_public_ticket_availability(uuid) from authenticated;
grant execute on function public.get_public_ticket_availability(uuid) to anon, authenticated;

-- =============================================================================
-- expire_pending_orders: idempotent lifecycle cleanup (RFC-006 section 43)
-- =============================================================================
-- Transitions PENDING_PAYMENT -> EXPIRED for orders whose hold window has
-- passed. This function affects ORDER LIFECYCLE BOOKKEEPING ONLY -
-- inventory correctness never depends on it having run (see this
-- migration's "Inventory model" section and `get_checkout_order`'s
-- EXPIRED derivation above, both of which are already timestamp-aware
-- independent of this function). RFC-006 wires up no caller for this
-- function (section 45: "No cron yet") - it exists so a later scheduled
-- job (Supabase's pg_cron, or a scheduled Edge Function calling this RPC
-- with the service_role key) can invoke it once that infrastructure is
-- introduced. Until then it can be run manually, e.g. via the Supabase
-- SQL editor as an admin, or with the service_role key.
--
-- SECURITY DEFINER for the same underlying reason as the other two
-- functions above (no `to <role>` UPDATE policy exists on `orders` for
-- anon/authenticated), but EXECUTE is granted to `service_role` ONLY -
-- this is a maintenance operation, never something a buyer or organizer
-- calls directly.
--
-- `where o.status = 'PENDING_PAYMENT'` in the UPDATE's own WHERE clause
-- (not just in a prior SELECT) is what makes re-running this function
-- safe: an order already EXPIRED, PAID, CANCELLED, REFUNDED, etc. simply
-- doesn't match the WHERE clause on a second run, so calling this twice
-- (or a thousand times) in a row is a no-op past the first successful
-- pass - true idempotence, not merely "doesn't error twice."
create function public.expire_pending_orders()
returns integer
language sql
security definer
set search_path = public, pg_temp
as $$
  with expired as (
    update public.orders o
    set status = 'EXPIRED'
    where o.status = 'PENDING_PAYMENT'
      and o.expires_at is not null
      and o.expires_at <= now()
    returning 1
  )
  select count(*)::integer from expired;
$$;

comment on function public.expire_pending_orders() is
  'RFC-006 idempotent lifecycle cleanup: PENDING_PAYMENT -> EXPIRED for orders whose hold has lapsed. Does NOT gate inventory correctness (see this migration''s header) - purely a bookkeeping transition for anything that reads orders.status directly (e.g. a future organizer dashboard). Returns the number of orders it just expired. No scheduled caller exists yet (RFC-006 "No cron yet") - intended to be invoked later by pg_cron or a scheduled Edge Function using service_role.';

revoke all on function public.expire_pending_orders() from public;
revoke all on function public.expire_pending_orders() from anon;
revoke all on function public.expire_pending_orders() from authenticated;
grant execute on function public.expire_pending_orders() to service_role;
