#!/usr/bin/env bash
#
# RFC-008 concurrency proof: many real, concurrent Postgres sessions all
# calling issue_tickets_for_order for the SAME already-PAID order at (as
# close as bash allows) the same instant.
#
# Why this script exists (same reasoning as scripts/rfc-006-concurrency-test.sh
# and scripts/rfc-007-concurrency-test.sh, which this mirrors): pgTAP's
# suite (supabase/tests/database/rfc_008_ticketing.test.sql) runs
# everything inside one backend/one transaction, so it can prove the
# unique-constraint backstop exists but it CANNOT exercise several
# overlapping transactions truly racing the SAME
# unique(organization_id, order_item_id, ticket_sequence) index - which is
# exactly what would happen in production if Mercado Pago redelivers a
# webhook notification several times in a short window, or a manual
# reconciliation tool runs at the same moment a redelivery is being
# processed.
#
# What it proves (the explicit requirement: "llamar a la emisión 1, 5, o
# 20 veces siempre debe dar el mismo resultado"):
#   - N concurrent calls to issue_tickets_for_order for an order with a
#     known quantity Q always leave exactly Q tickets - never more, never
#     fewer, regardless of how many concurrent calls raced each other or
#     in what order they committed.
#   - Every ticket's (order_item_id, ticket_sequence) pair is unique - the
#     database-level constraint, not application logic, is what enforced
#     this under real concurrency.
#
# How to run against a REAL local Supabase stack:
#   1. supabase start
#   2. supabase db reset      (applies all migrations, including RFC-008's)
#   3. DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
#        QR_ENCRYPTION_KEY="any-non-empty-test-value" \
#        ./scripts/rfc-008-concurrency-test.sh
#
# Same safety guard as RFC-006/007's scripts: refuses anything that isn't
# obviously local (never run a concurrency stress test against Supabase
# Cloud).

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
QR_ENCRYPTION_KEY="${QR_ENCRYPTION_KEY:-rfc008-concurrency-test-key}"
CONCURRENT_CALLS="${CONCURRENT_CALLS:-8}"

case "$DATABASE_URL" in
  *127.0.0.1*|*localhost*|*"host=/var/run/postgresql"*|*"host=/tmp"*)
    ;;
  *)
    echo "REFUSING to run: DATABASE_URL does not look like a local database." >&2
    echo "  DATABASE_URL=$DATABASE_URL" >&2
    echo "This script only runs against 127.0.0.1/localhost/a unix socket," >&2
    echo "to guarantee it can never touch Supabase Cloud." >&2
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

ORG_ID="08cc0000-0000-0000-0000-0000000000c1"
ORG_SLUG="rfc008-concurrency-org"
EVENT_ID="08cc0000-0000-0000-0000-0000000000c2"
EVENT_SLUG="rfc008-concurrency-show"
TT_ID="08cc0000-0000-0000-0000-0000000000c3"
TOKEN_HASH="dddddddd9999dddddddd9999dddddddd9999dddddddd9999dddddddd9999dddd"
PROVIDER_PAYMENT_ID="rfc008-concurrency-payment-001"
QUANTITY=3

cat > "$WORKDIR/setup.sql" <<SQL
begin;
insert into public.organizations (id, name, slug, currency, timezone) values
  ('$ORG_ID', 'RFC-008 Concurrency Org', '$ORG_SLUG', 'ARS', 'America/Argentina/Buenos_Aires')
  on conflict (id) do nothing;

insert into public.events (id, organization_id, name, slug, starts_at, venue_name, status) values
  ('$EVENT_ID', '$ORG_ID', 'RFC-008 Concurrency Show', '$EVENT_SLUG', now() + interval '30 days', 'Test Venue', 'DRAFT')
  on conflict (id) do nothing;

insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('$TT_ID', '$ORG_ID', '$EVENT_ID', 'Concurrency General', 100000, 'ARS', 20, 'PUBLIC', true)
  on conflict (id) do nothing;

update public.events set status = 'PUBLISHED' where id = '$EVENT_ID';
commit;
SQL

cat > "$WORKDIR/teardown.sql" <<SQL
begin;
delete from public.tickets where organization_id = '$ORG_ID';
delete from public.audit_logs where organization_id = '$ORG_ID';
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

echo "=== RFC-008 concurrent ticket-issuance idempotency test ==="
echo "Target: $DATABASE_URL"
echo "Concurrent calls: $CONCURRENT_CALLS, order quantity: $QUANTITY"
echo
echo "--- Setting up fixtures ---"
"${PSQL[@]}" -f "$WORKDIR/setup.sql"

echo
echo "--- Creating and paying the order (create_order_with_hold + confirm_order_payment, quantity=$QUANTITY) ---"
ORDER_ID="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  set role anon;
  select order_id from public.create_order_with_hold(
    '$ORG_SLUG', '$EVENT_SLUG',
    '[{\"ticketTypeId\": \"$TT_ID\", \"quantity\": $QUANTITY}]'::jsonb,
    'Concurrency Buyer', 'concurrency.buyer@example.test', null,
    '$TOKEN_HASH'
  );
")"
echo "Order id: $ORDER_ID"

# Deliberately transition the order to PAID WITHOUT going through
# confirm_order_payment (which would issue tickets itself as part of the
# same call) - this isolates the harder "zero tickets exist yet, N
# concurrent callers all race to be first" case, rather than the easier
# "tickets already exist, N concurrent callers all find nothing to do"
# case a real confirm_order_payment-driven setup would produce.
psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 -c "
  update public.orders set status = 'PAID', paid_at = now() where id = '$ORDER_ID';
" >/dev/null

TICKETS_BEFORE_RACE="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  select count(*) from public.tickets where order_id = '$ORDER_ID';
")"
echo "Tickets before the concurrent race: $TICKETS_BEFORE_RACE (expected: 0 - nothing has issued yet)"

run_issue() {
  # Same out-file/exit-file separation as RFC-006/007's scripts, for the
  # same reason: never let psql's own async stderr flushing race against
  # how we read the exit status back.
  local out_file="$1"
  local status=0
  psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
    -c "set role service_role;" \
    -c "select public.issue_tickets_for_order('$ORDER_ID'::uuid, '$QR_ENCRYPTION_KEY');" \
    > "$out_file" 2>&1 || status=$?
  echo "$status" > "$out_file.exit"
}

echo
echo "--- Firing $CONCURRENT_CALLS concurrent issue_tickets_for_order calls for the SAME already-PAID order ---"

PIDS=()
for i in $(seq 1 "$CONCURRENT_CALLS"); do
  run_issue "$WORKDIR/req_$i.out" &
  PIDS+=("$!")
done

FAILED_CALLS=0
for i in "${!PIDS[@]}"; do
  wait "${PIDS[$i]}" || true
done

for i in $(seq 1 "$CONCURRENT_CALLS"); do
  EXIT_CODE="$(cat "$WORKDIR/req_$i.out.exit")"
  COUNT="$(grep -E '^[[:space:]]*[0-9]+[[:space:]]*$' "$WORKDIR/req_$i.out" | tail -1 | tr -d '[:space:]')"
  echo "  call $i: exit=$EXIT_CODE newly_inserted=${COUNT:-?}"
  if [ "$EXIT_CODE" != "0" ]; then FAILED_CALLS=$((FAILED_CALLS+1)); fi
done

FINAL_TICKET_COUNT="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  select count(*) from public.tickets where order_id = '$ORDER_ID';
")"

DISTINCT_SLOT_COUNT="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  select count(distinct (order_item_id, ticket_sequence)) from public.tickets where order_id = '$ORDER_ID';
")"

echo
echo "Failed calls (unexpected non-zero exit):     $FAILED_CALLS (expected: 0)"
echo "Final ticket count for this order:           $FINAL_TICKET_COUNT (expected: $QUANTITY)"
echo "Distinct (order_item_id, ticket_sequence):   $DISTINCT_SLOT_COUNT (expected: $QUANTITY - no two tickets ever shared a slot)"

RESULT_OK=1
if [ "$FAILED_CALLS" -ne 0 ]; then RESULT_OK=0; fi
if [ "$FINAL_TICKET_COUNT" != "$QUANTITY" ]; then RESULT_OK=0; fi
if [ "$DISTINCT_SLOT_COUNT" != "$QUANTITY" ]; then RESULT_OK=0; fi

echo
if [ "$RESULT_OK" -eq 1 ]; then
  echo "RESULT: PASS - $CONCURRENT_CALLS concurrent issuance calls for the same order converged to exactly $QUANTITY tickets, never duplicated."
  exit 0
else
  echo "RESULT: FAIL - see output above."
  exit 1
fi
