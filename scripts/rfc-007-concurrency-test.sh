#!/usr/bin/env bash
#
# RFC-007 concurrency proof: two real, concurrent Postgres sessions
# delivering the SAME Mercado Pago webhook notification (same
# provider_payment_id) for the same order at (as close as bash allows) the
# same instant, racing on confirm_order_payment's row lock + the payments
# table's UNIQUE(provider, provider_payment_id) constraint.
#
# Why this script exists (same reasoning as scripts/rfc-006-concurrency-test.sh,
# which this mirrors): pgTAP's suite (supabase/tests/database/rfc_007_payments.test.sql)
# runs everything inside one backend/one transaction, so it can prove the
# unique-constraint backstop exists (a second raw INSERT with the same key
# throws unique_violation) but it CANNOT exercise two overlapping
# transactions truly racing on confirm_order_payment's `for update` lock.
# This script opens two independent `psql` connections and fires both at
# once against a database that is already running.
#
# What it proves (RFC-007 sections 28/56/66/67 - "webhook processing MUST
# be idempotent... same notification delivered multiple times must result
# in one logical transition, never duplicate tickets/side effects"):
#   - Exactly ONE of the two concurrent confirm_order_payment calls
#     produces the real transition (outcome 'PAID' or 'PAID_LATE_RECOVERY').
#   - The other resolves to 'ALREADY_PROCESSED', pointing at the SAME
#     payment_id the winner produced - never a second, distinct payment row.
#   - Exactly one row exists in `payments` for that (provider,
#     provider_payment_id) afterwards, regardless of which call "won".
#   - The order ends up PAID exactly once - never oversold, never left
#     PENDING_PAYMENT, never double-charged in Lucky Ticket's own records.
#
# How to run against a REAL local Supabase stack:
#   1. supabase start
#   2. supabase db reset      (applies all migrations, including RFC-007's)
#   3. DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
#        ./scripts/rfc-007-concurrency-test.sh
#
# Same safety guard as RFC-006's script: refuses anything that isn't
# obviously local (RFC-007's own repeated instruction: never run
# destructive testing, and certainly never a race-condition stress test,
# against Supabase Cloud).

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

case "$DATABASE_URL" in
  *127.0.0.1*|*localhost*|*"host=/var/run/postgresql"*|*"host=/tmp"*)
    ;;
  *)
    echo "REFUSING to run: DATABASE_URL does not look like a local database." >&2
    echo "  DATABASE_URL=$DATABASE_URL" >&2
    echo "This script only runs against 127.0.0.1/localhost/a unix socket," >&2
    echo "to guarantee it can never touch Supabase Cloud (RFC-007's repeated" >&2
    echo "\"never run destructive operations against Cloud\" instruction)." >&2
    exit 1
    ;;
esac

PSQL=(psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1)

WORKDIR="$(mktemp -d)"
trap 'cleanup' EXIT

cleanup() {
  echo
  echo "--- Cleaning up fixtures ---"
  "${PSQL[@]}" -f "$WORKDIR/teardown.sql" >/dev/null 2>&1 || true
  rm -rf "$WORKDIR"
}

ORG_ID="07cc0000-0000-0000-0000-0000000000c1"
ORG_SLUG="rfc007-concurrency-org"
EVENT_ID="07cc0000-0000-0000-0000-0000000000c2"
EVENT_SLUG="rfc007-concurrency-show"
TT_ID="07cc0000-0000-0000-0000-0000000000c3"
TOKEN_HASH="cccccccc9999cccccccc9999cccccccc9999cccccccc9999cccccccc9999cccc"
PROVIDER_PAYMENT_ID="rfc007-concurrency-payment-001"

cat > "$WORKDIR/setup.sql" <<SQL
begin;
insert into public.organizations (id, name, slug, currency, timezone) values
  ('$ORG_ID', 'RFC-007 Concurrency Org', '$ORG_SLUG', 'ARS', 'America/Argentina/Buenos_Aires')
  on conflict (id) do nothing;

insert into public.events (id, organization_id, name, slug, starts_at, venue_name, status) values
  ('$EVENT_ID', '$ORG_ID', 'RFC-007 Concurrency Show', '$EVENT_SLUG', now() + interval '30 days', 'Test Venue', 'DRAFT')
  on conflict (id) do nothing;

insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('$TT_ID', '$ORG_ID', '$EVENT_ID', 'Concurrency General', 100000, 'ARS', 10, 'PUBLIC', true)
  on conflict (id) do nothing;

update public.events set status = 'PUBLISHED' where id = '$EVENT_ID';
commit;
SQL

cat > "$WORKDIR/teardown.sql" <<SQL
begin;
delete from public.payments where organization_id = '$ORG_ID';
delete from public.ticket_holds where event_id = '$EVENT_ID';
delete from public.order_items where organization_id = '$ORG_ID';
delete from public.orders where organization_id = '$ORG_ID';
delete from public.customers where organization_id = '$ORG_ID';
delete from public.ticket_types where organization_id = '$ORG_ID';
delete from public.events where organization_id = '$ORG_ID';
delete from public.organizations where id = '$ORG_ID';
commit;
SQL

echo "=== RFC-007 concurrent-webhook idempotency test ==="
echo "Target: $DATABASE_URL"
echo
echo "--- Setting up fixtures ---"
"${PSQL[@]}" -f "$WORKDIR/setup.sql"

echo
echo "--- Creating the order to be paid (via create_order_with_hold, as anon) ---"
ORDER_ID="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  set role anon;
  select order_id from public.create_order_with_hold(
    '$ORG_SLUG', '$EVENT_SLUG',
    '[{\"ticketTypeId\": \"$TT_ID\", \"quantity\": 1}]'::jsonb,
    'Concurrency Buyer', 'concurrency.buyer@example.test', null,
    '$TOKEN_HASH'
  );
")"
echo "Order id: $ORDER_ID"

ORDER_TOTAL="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  select total_amount from public.orders where id = '$ORDER_ID';
")"
echo "Order total (minor units): $ORDER_TOTAL"

run_confirm() {
  # Same out-file/exit-file separation as RFC-006's script, for the same
  # reason: never let psql's own async stderr flushing race against how
  # we read the exit status back.
  local out_file="$1"
  local status=0
  psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
    -c "set role service_role;" \
    -c "select * from public.confirm_order_payment(
          '$ORDER_ID'::uuid, 'MERCADO_PAGO'::public.payment_provider,
          '$PROVIDER_PAYMENT_ID', 'APPROVED'::public.payment_status,
          $ORDER_TOTAL::bigint, 'ARS'::char(3), 'credit_card',
          '{}'::jsonb, now(), null
        );" \
    > "$out_file" 2>&1 || status=$?
  echo "$status" > "$out_file.exit"
}

echo
echo "--- Firing two concurrent confirm_order_payment calls for the SAME provider_payment_id ---"

run_confirm "$WORKDIR/req_a.out" &
PID_A=$!
run_confirm "$WORKDIR/req_b.out" &
PID_B=$!

wait "$PID_A" || true
wait "$PID_B" || true

EXIT_A="$(cat "$WORKDIR/req_a.out.exit")"
EXIT_B="$(cat "$WORKDIR/req_b.out.exit")"

echo "Call A exit code: $EXIT_A"
sed 's/^/  [A] /' "$WORKDIR/req_a.out"
echo "Call B exit code: $EXIT_B"
sed 's/^/  [B] /' "$WORKDIR/req_b.out"

WINNER_COUNT=0
grep -qE "PAID(_LATE_RECOVERY)?" "$WORKDIR/req_a.out" && WINNER_COUNT=$((WINNER_COUNT+1))
grep -qE "PAID(_LATE_RECOVERY)?" "$WORKDIR/req_b.out" && WINNER_COUNT=$((WINNER_COUNT+1))

ALREADY_PROCESSED_COUNT=0
grep -q "ALREADY_PROCESSED" "$WORKDIR/req_a.out" && ALREADY_PROCESSED_COUNT=$((ALREADY_PROCESSED_COUNT+1))
grep -q "ALREADY_PROCESSED" "$WORKDIR/req_b.out" && ALREADY_PROCESSED_COUNT=$((ALREADY_PROCESSED_COUNT+1))

PAYMENT_ROW_COUNT="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  select count(*) from public.payments
  where provider = 'MERCADO_PAGO' and provider_payment_id = '$PROVIDER_PAYMENT_ID';
")"

FINAL_ORDER_STATUS="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  select status from public.orders where id = '$ORDER_ID';
")"

echo
echo "Winning ('PAID'/'PAID_LATE_RECOVERY') calls: $WINNER_COUNT (expected: 1)"
echo "'ALREADY_PROCESSED' calls:                   $ALREADY_PROCESSED_COUNT (expected: 1)"
echo "payments rows for this provider_payment_id:  $PAYMENT_ROW_COUNT (expected: 1)"
echo "Final order status:                          $FINAL_ORDER_STATUS (expected: PAID)"

RESULT_OK=1
if [ "$EXIT_A" != "0" ] || [ "$EXIT_B" != "0" ]; then RESULT_OK=0; fi
if [ "$WINNER_COUNT" -ne 1 ] || [ "$ALREADY_PROCESSED_COUNT" -ne 1 ]; then RESULT_OK=0; fi
if [ "$PAYMENT_ROW_COUNT" != "1" ]; then RESULT_OK=0; fi
if [ "$FINAL_ORDER_STATUS" != "PAID" ]; then RESULT_OK=0; fi

echo
if [ "$RESULT_OK" -eq 1 ]; then
  echo "RESULT: PASS - the same webhook notification processed twice concurrently had exactly one logical effect (RFC-007 invariant 3)."
  exit 0
else
  echo "RESULT: FAIL - see output above."
  exit 1
fi
