-- RFC-007: Mercado Pago Checkout Pro & Payment Processing.
--
-- Introduces real payment infrastructure on top of RFC-006's trusted
-- PENDING_PAYMENT state: creating a Mercado Pago Checkout Pro preference,
-- and atomically confirming a provider-verified payment into PAID.
--
-- This migration does NOT redesign any existing table. RFC-002 already
-- has everything the payment/webhook data model needs (`payments` with
-- `UNIQUE(provider, provider_payment_id)`, `webhook_events` with
-- `UNIQUE(provider, provider_event_id)`, `payment_accounts` as
-- connection-metadata-only). Two nullable columns are added to `orders`
-- (see "SCHEMA CHANGE" below) because RFC-002 never anticipated needing
-- to correlate an order with a Mercado Pago preference before any payment
-- exists. No other schema change was necessary - see
-- docs/rfcs/RFC-007-mercado-pago-payments.md "Inspect existing
-- architecture first" for the full inventory of what was checked before
-- writing this file.
--
-- =============================================================================
-- WHY THIS MUST STAY SECURITY DEFINER FUNCTIONS, NOT NEW RLS POLICIES
-- =============================================================================
-- Same reasoning as RFC-006 (see that migration's header): RLS policies
-- are per-row, not per-transaction, and cannot express "lock this order
-- row, re-verify amount/currency/state, and only then flip status and
-- insert a payment as one atomic unit." Two SECURITY DEFINER functions are
-- added:
--
--   1. `record_payment_preference` - callable by `anon`/`authenticated`,
--      same trust boundary as RFC-006's `create_order_with_hold`
--      /`get_checkout_order`: the caller proves authorization by already
--      holding the order's `checkout_token_hash` pre-image (the raw
--      checkout token), which this function re-verifies itself. It never
--      trusts a bare order id.
--
--   2. `confirm_order_payment` - the payment-truth boundary (RFC-007
--      invariants 1-4). Grant EXECUTE to `service_role` ONLY (same
--      pattern as RFC-006's `expire_pending_orders`), never to
--      `anon`/`authenticated` - see RFC-007 section 53: "Do not expose
--      payment confirmation RPCs to anon/authenticated." A caller who
--      merely knows an order id and can fabricate a JSON body must NEVER
--      be able to mark that order PAID; only trusted server-side code
--      that has ALREADY independently verified a payment with Mercado
--      Pago's own API (never the webhook body alone) may call this, using
--      a service-role Supabase client
--      (`src/lib/supabase/service-role.ts`) that exists for exactly this
--      one purpose.
--
-- `get_checkout_order` is redefined (DROP + CREATE, in this NEW migration
-- file - the RFC-006 migration file itself is never edited) purely to add
-- two output columns (`provider_preference_id`, `provider_checkout_url`)
-- so the checkout page and preference-creation endpoint can reuse the
-- SAME "narrow checkout read boundary" RFC-006 already established,
-- instead of inventing a second, parallel read path (RFC-007 section 4:
-- "Reuse the existing RFC-006 implementation instead of duplicating
-- checkout logic"). Its authorization semantics (order id + checkout
-- token hash, nothing else) and every previously-returned column are
-- unchanged.
--
-- =============================================================================
-- SCHEMA CHANGE: orders.provider_preference_id / orders.provider_checkout_url
-- =============================================================================
-- A Mercado Pago Checkout Pro preference is created BEFORE any payment
-- exists (the buyer hasn't reached Mercado Pago yet), so there is no
-- `payments` row yet to attach a preference id to - `payments` rows are
-- only ever created from a real provider payment (see
-- `confirm_order_payment` below), one per `provider_payment_id`. The
-- preference instead correlates 1:1 with the ORDER it was created for
-- (RFC-007 section 27: "be able to reconcile Lucky Ticket order <->
-- Mercado Pago preference <-> Mercado Pago payment"), and is reused across
-- repeated "Continuar al pago" clicks for the same still-valid order
-- (RFC-007 section 36) rather than minted again on every click - both
-- columns live on `orders` for that reason. `provider_checkout_url` is
-- stored alongside the id (not re-derived from it) so a reuse never needs
-- a second Mercado Pago API round trip just to recover the redirect URL.
alter table public.orders
  add column provider_preference_id text,
  add column provider_checkout_url text;

alter table public.orders
  add constraint orders_provider_preference_id_key unique (provider_preference_id);

comment on column public.orders.provider_preference_id is
  'Mercado Pago Checkout Pro preference id for this order, set by record_payment_preference() once created. NULL until "Continuar al pago" is first pressed. Unique so two orders can never share a preference.';
comment on column public.orders.provider_checkout_url is
  'The preference''s buyer-facing redirect URL (init_point/sandbox_init_point), stored so a repeated request can reuse it without a second Mercado Pago API call.';

-- =============================================================================
-- get_checkout_order (redefined): adds provider_preference_id/provider_checkout_url
-- =============================================================================
-- DROP is required (not CREATE OR REPLACE) because the output column list
-- is changing - Postgres does not allow CREATE OR REPLACE FUNCTION to
-- change a function's return type. This is a live redefinition of the
-- FUNCTION, not an edit to the RFC-006 migration FILE, which remains
-- byte-for-byte untouched (forward-only migrations - RFC-007 section 5).
drop function if exists public.get_checkout_order(uuid, text);

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
  organization_id uuid,
  organization_name text,
  organization_timezone text,
  items jsonb,
  provider_preference_id text,
  provider_checkout_url text
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
      v_order.organization_id,
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
      ),
      v_order.provider_preference_id,
      v_order.provider_checkout_url
    from public.events e
    join public.organizations org on org.id = v_order.organization_id
    where e.organization_id = v_order.organization_id
      and e.id = v_order.event_id;
end;
$$;

comment on function public.get_checkout_order(uuid, text) is
  'RFC-006 narrow checkout read boundary, extended by RFC-007 to also return provider_preference_id/provider_checkout_url. Requires BOTH the order id and a matching checkout_token_hash - an order id alone authorizes nothing. Never returns buyer_name/buyer_email/checkout_token_hash or any other customer/internal field beyond what the checkout confirmation page and payment-preference endpoint need.';

revoke all on function public.get_checkout_order(uuid, text) from public;
revoke all on function public.get_checkout_order(uuid, text) from anon;
revoke all on function public.get_checkout_order(uuid, text) from authenticated;
grant execute on function public.get_checkout_order(uuid, text) to anon, authenticated;

-- =============================================================================
-- record_payment_preference: persist a Checkout Pro preference against its order
-- =============================================================================
-- Called AFTER the Next.js route has already created (or decided to reuse)
-- a Mercado Pago preference - this function only persists the correlation,
-- it never talks to Mercado Pago itself (no network I/O in Postgres, by
-- design). Re-verifies the checkout token and the order's payable state
-- itself (never trusts that the caller already checked, for the same
-- reason `create_order_with_hold` re-validates everything - RFC-006
-- section 17 precedent) so this function alone is sufficient authorization,
-- matching the narrow-interface/no-trust-caller checklist RFC-006's
-- migration header documents for its own SECURITY DEFINER functions.
create function public.record_payment_preference(
  p_order_id uuid,
  p_checkout_token_hash text,
  p_provider public.payment_provider,
  p_provider_preference_id text,
  p_provider_checkout_url text
)
returns table (
  order_id uuid,
  provider_preference_id text,
  provider_checkout_url text
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

  if btrim(coalesce(p_provider_preference_id, '')) = '' or btrim(coalesce(p_provider_checkout_url, '')) = '' then
    raise exception 'malformed preference' using errcode = '22023';
  end if;

  select o.*
    into v_order
    from public.orders o
    where o.id = p_order_id
      and o.checkout_token_hash = p_checkout_token_hash
    for update;

  if not found then
    raise exception 'invalid checkout token' using errcode = 'LT008';
  end if;

  -- Authoritative, timestamp-aware payability check - identical predicate
  -- to get_checkout_order's virtual EXPIRED derivation, so a caller can
  -- never create/persist a preference for an order the buyer is already
  -- being told is expired (RFC-007 section 35).
  if v_order.status <> 'PENDING_PAYMENT' or v_order.expires_at <= now() then
    raise exception 'order is not payable' using errcode = 'LT011';
  end if;

  update public.orders
    set provider_preference_id = p_provider_preference_id,
        provider_checkout_url = p_provider_checkout_url
    where id = v_order.id;

  return query select v_order.id, p_provider_preference_id, p_provider_checkout_url;
end;
$$;

comment on function public.record_payment_preference(uuid, text, public.payment_provider, text, text) is
  'RFC-007: persists a Mercado Pago Checkout Pro preference id/redirect URL against its order, after independently re-verifying the checkout token and that the order is still PENDING_PAYMENT and unexpired. Never calls out to a payment provider itself - see src/features/payments/api.ts for the orchestration.';

revoke all on function public.record_payment_preference(uuid, text, public.payment_provider, text, text) from public;
revoke all on function public.record_payment_preference(uuid, text, public.payment_provider, text, text) from anon;
revoke all on function public.record_payment_preference(uuid, text, public.payment_provider, text, text) from authenticated;
grant execute on function public.record_payment_preference(uuid, text, public.payment_provider, text, text) to anon, authenticated;

-- =============================================================================
-- confirm_order_payment: the payment-truth boundary (RFC-007 invariants 1-4)
-- =============================================================================
-- Called ONLY from trusted server-side webhook processing
-- (src/app/api/webhooks/mercado-pago/route.ts), AFTER that code has
-- already: verified the webhook signature, fetched the payment resource
-- from Mercado Pago's own API (never trusting the webhook body), and
-- mapped the provider's status string into `p_status` via
-- src/lib/mercado-pago/mapper.ts. This function performs the SINGLE
-- atomic transaction that may transition an order to PAID - every
-- invariant is re-checked here, in Postgres, under a row lock, because
-- that is the only place "lock order, validate, insert payment, transition
-- status" can happen as one indivisible unit.
--
-- Idempotency (RFC-007 sections 28/66/67): `payments` already has
-- `UNIQUE(provider, provider_payment_id)` from RFC-002. This function
-- checks for an existing row with that key FIRST and returns
-- 'ALREADY_PROCESSED' as a pure no-op if found; if two concurrent calls
-- both pass that check before either commits, the second INSERT itself
-- raises `unique_violation`, which is caught below and turned into the
-- same 'ALREADY_PROCESSED' outcome - so the database's own uniqueness
-- constraint is the ultimate backstop, not application-level
-- check-then-insert alone (RFC-007 section 56).
--
-- Amount/currency validation (sections 24/25): `p_paid_amount_minor` and
-- `p_currency` must already be integer minor units / ISO-4217 by the time
-- they reach this function - the float-to-minor-units conversion boundary
-- lives entirely in src/lib/mercado-pago/mapper.ts, never here and never
-- with floating-point comparison.
--
-- Payment-vs-expiration race (section 33): if the order is not currently
-- in its normal payable window (status literally EXPIRED, or still
-- PENDING_PAYMENT but past `expires_at` because `expire_pending_orders()`
-- has not run yet), this function does NOT immediately reject a genuinely
-- approved payment. It re-derives current availability for every ticket
-- type on the order - the SAME formula as RFC-006's
-- `get_public_ticket_availability`/`create_order_with_hold`, this time
-- excluding the order's own (no-longer-counted) hold - under a fresh
-- `for update` lock on each `ticket_types` row (ascending id order, same
-- deadlock-avoidance convention as `create_order_with_hold`). Only if
-- every line still fits does it allow the late PAID transition
-- ('PAID_LATE_RECOVERY'); otherwise it records the payment (full audit
-- trail preserved) without moving the order, returning
-- 'REJECTED_INVENTORY_UNAVAILABLE' for manual reconciliation - "do not
-- oversell" always wins over "the payment arrived late."
--
-- Inventory double-counting (section 34): no explicit "release the hold"
-- step exists or is needed. RFC-006's inventory formula already stops
-- counting a hold the instant its order's status leaves
-- 'PENDING_PAYMENT' (the join filters on `o.status = 'PENDING_PAYMENT'`),
-- and starts counting the same quantity via `order_items` the instant
-- status becomes 'PAID' - so the single `update orders set status =
-- 'PAID'` below is both changes at once, atomically, with no window where
-- the quantity is counted twice or not at all.
create function public.confirm_order_payment(
  p_order_id uuid,
  p_provider public.payment_provider,
  p_provider_payment_id text,
  p_status public.payment_status,
  p_paid_amount_minor bigint,
  p_currency char(3),
  p_payment_method text,
  p_provider_payload jsonb,
  p_approved_at timestamptz,
  p_webhook_event_id uuid
)
returns table (
  outcome text,
  order_id uuid,
  order_status text,
  payment_id uuid
)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_order public.orders%rowtype;
  v_existing_payment_id uuid;
  v_existing_payment_status public.payment_status;
  v_payment_id uuid;
  v_item record;
  v_committed bigint;
  v_held bigint;
  v_capacity integer;
  v_available bigint;
  v_inventory_ok boolean := true;
  v_late_recovery boolean := false;
begin
  if p_order_id is null or btrim(coalesce(p_provider_payment_id, '')) = '' then
    raise exception 'order and provider payment id are required' using errcode = 'LT010';
  end if;

  -- Lock the order FIRST: this is the single serialization point for
  -- every concurrent caller touching this order (two webhook deliveries,
  -- a webhook racing a future manual-reconciliation tool, etc. - section 32).
  select o.* into v_order from public.orders o where o.id = p_order_id for update;

  if not found then
    raise exception 'order not found for payment' using errcode = 'LT010';
  end if;

  -- Idempotency fast path (sections 28/30/66): a payment id already
  -- recorded, for ANY order, is never processed twice. Re-delivered
  -- webhooks for a payment already reconciled return the same answer
  -- every time with zero additional side effects. A later status change
  -- on the SAME provider_payment_id (e.g. a subsequent refund/chargeback)
  -- is intentionally out of RFC-007's scope (see non-goals: refunds,
  -- chargebacks) and is also absorbed here as a safe no-op rather than
  -- mutating already-settled state.
  select id, status into v_existing_payment_id, v_existing_payment_status
    from public.payments
    where provider = p_provider and provider_payment_id = p_provider_payment_id;

  if found then
    return query select 'ALREADY_PROCESSED'::text, v_order.id, v_order.status::text, v_existing_payment_id;
    return;
  end if;

  begin
    insert into public.payments (
      organization_id, order_id, provider, provider_payment_id,
      status, paid_amount, currency, payment_method, provider_payload, approved_at
    ) values (
      v_order.organization_id, v_order.id, p_provider, p_provider_payment_id,
      p_status, p_paid_amount_minor, p_currency, p_payment_method,
      coalesce(p_provider_payload, '{}'::jsonb), p_approved_at
    )
    returning id into v_payment_id;
  exception when unique_violation then
    -- Lost a race against a concurrent call for the exact same provider
    -- payment id (section 67) - the unique constraint is the backstop the
    -- SELECT above could not fully guarantee under concurrency.
    select id into v_payment_id
      from public.payments
      where provider = p_provider and provider_payment_id = p_provider_payment_id;

    return query select 'ALREADY_PROCESSED'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end;

  if p_webhook_event_id is not null then
    update public.webhook_events
      set status = 'PROCESSED', processed_at = now()
      where id = p_webhook_event_id;
  end if;

  -- A payment attempt was recorded but the provider itself does not
  -- consider it a successful payment (pending/in_process/rejected/
  -- cancelled/...). The order's lifecycle is untouched - a rejected
  -- attempt must not destroy a still-valid reservation the buyer can
  -- retry against (sections 39/40/69).
  if p_status <> 'APPROVED' then
    return query select 'RECORDED_NOT_APPROVED'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  if v_order.status = 'PAID' then
    -- A second, DIFFERENT approved payment id for an order already PAID
    -- (e.g. buyer double-paid) must never re-transition or double-commit
    -- inventory - the order is already in its terminal success state.
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_order.organization_id, 'payment_approved_order_already_paid', 'order', v_order.id,
      jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'paymentId', v_payment_id)
    );
    return query select 'ORDER_ALREADY_PAID'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  if v_order.status not in ('PENDING_PAYMENT', 'EXPIRED') then
    -- CANCELLED / PAYMENT_FAILED / REFUNDED / PARTIALLY_REFUNDED: not a
    -- state this RFC ever transitions into PAID.
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_order.organization_id, 'payment_approved_order_not_payable', 'order', v_order.id,
      jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'orderStatus', v_order.status, 'paymentId', v_payment_id)
    );
    return query select 'REJECTED_ORDER_STATE'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  if p_currency <> v_order.currency then
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_order.organization_id, 'payment_currency_mismatch', 'order', v_order.id,
      jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'orderCurrency', v_order.currency, 'paymentCurrency', p_currency, 'paymentId', v_payment_id)
    );
    return query select 'REJECTED_CURRENCY_MISMATCH'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  if p_paid_amount_minor <> v_order.total_amount then
    insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
    values (
      v_order.organization_id, 'payment_amount_mismatch', 'order', v_order.id,
      jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'orderTotalAmount', v_order.total_amount, 'paymentAmount', p_paid_amount_minor, 'paymentId', v_payment_id)
    );
    return query select 'REJECTED_AMOUNT_MISMATCH'::text, v_order.id, v_order.status::text, v_payment_id;
    return;
  end if;

  v_late_recovery := not (v_order.status = 'PENDING_PAYMENT' and v_order.expires_at > now());

  if v_late_recovery then
    -- Payment-vs-expiration race (section 33): re-verify capacity,
    -- excluding this order's own (no-longer-counted) hold, before
    -- allowing a late PAID transition. Lock every affected ticket_types
    -- row in ascending id order first (same convention as
    -- create_order_with_hold) to prevent a race with a concurrent new
    -- checkout for the same ticket type.
    for v_item in
      select oi.ticket_type_id, oi.quantity
        from public.order_items oi
        where oi.organization_id = v_order.organization_id
          and oi.order_id = v_order.id
        order by oi.ticket_type_id
    loop
      perform 1 from public.ticket_types tt where tt.id = v_item.ticket_type_id for update;

      select tt.quantity into v_capacity
        from public.ticket_types tt
        where tt.id = v_item.ticket_type_id;

      select coalesce(sum(oi2.quantity), 0) into v_committed
        from public.order_items oi2
        join public.orders o2
          on o2.organization_id = oi2.organization_id
         and o2.id = oi2.order_id
        where oi2.organization_id = v_order.organization_id
          and oi2.ticket_type_id = v_item.ticket_type_id
          and o2.status = 'PAID';

      select coalesce(sum(h.quantity), 0) into v_held
        from public.ticket_holds h
        join public.orders o3
          on o3.organization_id = h.organization_id
         and o3.id = h.order_id
        where h.organization_id = v_order.organization_id
          and h.ticket_type_id = v_item.ticket_type_id
          and o3.status = 'PENDING_PAYMENT'
          and h.expires_at > now()
          and o3.id <> v_order.id;

      v_available := v_capacity::bigint - v_committed - v_held;

      if v_item.quantity > v_available then
        v_inventory_ok := false;
        exit;
      end if;
    end loop;

    if not v_inventory_ok then
      insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
      values (
        v_order.organization_id, 'payment_approved_inventory_unavailable', 'order', v_order.id,
        jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'paymentId', v_payment_id)
      );
      return query select 'REJECTED_INVENTORY_UNAVAILABLE'::text, v_order.id, v_order.status::text, v_payment_id;
      return;
    end if;
  end if;

  update public.orders
    set status = 'PAID', paid_at = coalesce(p_approved_at, now())
    where id = v_order.id;

  insert into public.audit_logs (organization_id, action, entity_type, entity_id, metadata)
  values (
    v_order.organization_id,
    case when v_late_recovery then 'order_paid_late_recovery' else 'order_paid' end,
    'order', v_order.id,
    jsonb_build_object('provider', p_provider, 'providerPaymentId', p_provider_payment_id, 'paymentId', v_payment_id)
  );

  return query select
    (case when v_late_recovery then 'PAID_LATE_RECOVERY' else 'PAID' end)::text,
    v_order.id, 'PAID'::text, v_payment_id;
end;
$$;

comment on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid) is
  'RFC-007 payment-truth boundary. SECURITY DEFINER, service_role EXECUTE only - never anon/authenticated (section 53). Locks the order row first, is idempotent per (provider, provider_payment_id) via RFC-002''s existing unique constraint, independently validates order state/currency/amount before any PAID transition, and re-verifies inventory capacity (excluding this order''s own hold) before allowing a late/expired-window recovery. Never trusts its caller''s inputs as already-authoritative - every value was independently fetched from Mercado Pago''s API by the caller before this function is invoked, and every invariant is re-checked here regardless.';

revoke all on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid) from public;
revoke all on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid) from anon;
revoke all on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid) from authenticated;
grant execute on function public.confirm_order_payment(uuid, public.payment_provider, text, public.payment_status, bigint, char(3), text, jsonb, timestamptz, uuid) to service_role;

-- =============================================================================
-- record_webhook_event: the ONLY insert path into webhook_events
-- =============================================================================
-- Idempotent at the database level via RFC-002's existing
-- `webhook_events_provider_event_key` unique constraint: a retried
-- delivery of the same provider_event_id is a safe no-op that returns the
-- EXISTING row's id (so the caller can tell "already seen" apart from
-- "brand new") rather than raising or creating a duplicate. Called before
-- `confirm_order_payment` so a webhook's receipt is durably recorded even
-- if signature/lookup validation fails later in the same request -
-- observability first (RFC-007 section 29).
create function public.record_webhook_event(
  p_provider public.payment_provider,
  p_provider_event_id text,
  p_event_type text,
  p_payload jsonb
)
returns table (webhook_event_id uuid, already_existed boolean, status public.webhook_status)
language plpgsql
security definer
set search_path = public, pg_temp
as $$
declare
  v_id uuid;
  v_status public.webhook_status;
begin
  if btrim(coalesce(p_provider_event_id, '')) = '' or btrim(coalesce(p_event_type, '')) = '' then
    raise exception 'provider event id and type are required' using errcode = '22023';
  end if;

  -- The INSERT target is aliased ("as we") and RETURNING is qualified
  -- (we.id, we.status) because this function's own RETURNS TABLE declares
  -- an output column literally named `status` - inside a plpgsql function
  -- body, RETURNS TABLE column names are visible as implicit variables for
  -- the whole function, so an unqualified `status` in RETURNING is
  -- ambiguous between that variable and webhook_events.status (Postgres
  -- error 42702, caught by real pgTAP execution against a live database -
  -- see docs/rfcs/RFC-007-mercado-pago-payments.md "Known limitations"/
  -- validation notes). Qualifying with the table alias removes the
  -- ambiguity outright rather than relying on scope/precedence rules.
  insert into public.webhook_events as we (provider, provider_event_id, event_type, payload, status)
  values (p_provider, p_provider_event_id, p_event_type, coalesce(p_payload, '{}'::jsonb), 'RECEIVED')
  on conflict (provider, provider_event_id) do nothing
  returning we.id, we.status into v_id, v_status;

  if v_id is not null then
    return query select v_id, false, v_status;
    return;
  end if;

  -- Same ambiguity class as the RETURNING clause above - alias and
  -- qualify every column so `status` can never be read as the RETURNS
  -- TABLE output variable of the same name.
  select w.id, w.status into v_id, v_status
    from public.webhook_events w
    where w.provider = p_provider and w.provider_event_id = p_provider_event_id;

  return query select v_id, true, v_status;
end;
$$;

comment on function public.record_webhook_event(public.payment_provider, text, text, jsonb) is
  'RFC-007: durably records receipt of a webhook delivery, idempotently (RFC-002''s webhook_events_provider_event_key unique constraint), returning the row''s CURRENT status so a caller can tell "already fully processed" (safe to no-op) apart from "seen but not yet processed/failed" (safe to retry). service_role EXECUTE only - webhook_events has zero client-role RLS policies (RFC-002) and this function is only ever called from the trusted webhook Route Handler.';

revoke all on function public.record_webhook_event(public.payment_provider, text, text, jsonb) from public;
revoke all on function public.record_webhook_event(public.payment_provider, text, text, jsonb) from anon;
revoke all on function public.record_webhook_event(public.payment_provider, text, text, jsonb) from authenticated;
grant execute on function public.record_webhook_event(public.payment_provider, text, text, jsonb) to service_role;

-- =============================================================================
-- mark_webhook_event: terminal bookkeeping for events confirm_order_payment
-- never reaches (invalid signature, unsupported type, malformed body, or a
-- rejected reconciliation outcome it already returned without a
-- p_webhook_event_id - see the route handler for exactly which cases call
-- this vs. letting confirm_order_payment mark PROCESSED itself)
-- =============================================================================
create function public.mark_webhook_event(
  p_webhook_event_id uuid,
  p_status public.webhook_status,
  p_error_message text
)
returns void
language sql
security definer
set search_path = public, pg_temp
as $$
  update public.webhook_events
  set status = p_status,
      processed_at = now(),
      error_message = p_error_message
  where id = p_webhook_event_id;
$$;

comment on function public.mark_webhook_event(uuid, public.webhook_status, text) is
  'RFC-007: marks a previously-recorded webhook_events row PROCESSED/FAILED/IGNORED with a safe (no secrets, no raw provider payload) diagnostic message. service_role EXECUTE only.';

revoke all on function public.mark_webhook_event(uuid, public.webhook_status, text) from public;
revoke all on function public.mark_webhook_event(uuid, public.webhook_status, text) from anon;
revoke all on function public.mark_webhook_event(uuid, public.webhook_status, text) from authenticated;
grant execute on function public.mark_webhook_event(uuid, public.webhook_status, text) to service_role;
