#!/usr/bin/env bash
#
# RFC-006 concurrency proof: two real, concurrent Postgres sessions racing
# for the last unit of a capacity=1 ticket type, plus a deterministic-lock-
# ordering / deadlock check for overlapping multi-ticket carts.
#
# Why this script exists (RFC-006 section 59):
#   "Sequential tests are NOT enough to prove concurrency safety... Do not
#   claim concurrency safety only because the implementation uses a lock.
#   Prove the behavior." pgTAP runs everything inside one backend/one
#   transaction, so it CANNOT exercise two overlapping transactions racing
#   on the same row lock. This script opens two independent `psql`
#   connections and launches them at (as close as bash allows to)
#   the same instant with `&` / `wait`, against a database that is already
#   running (not inside a wrapping transaction this script controls), so
#   Postgres's real MVCC/row-locking behavior is what decides the outcome.
#
# What it proves:
#   Scenario 1 (RFC-006 section 12/59): a General Admission ticket type with
#   capacity=1. Request A and Request B each ask for 1 ticket, fired
#   concurrently. Expected: exactly ONE succeeds, the other fails with the
#   stable domain error LT005 (INSUFFICIENT_INVENTORY). Never both succeed
#   (overselling), never both fail.
#
#   Scenario 2 (RFC-006 section 13/60): two cartts that touch the SAME two
#   ticket types in OPPOSITE order (Order A: General then VIP; Order B: VIP
#   then General), fired concurrently, where both ticket types have enough
#   capacity for both orders to succeed. Because create_order_with_hold
#   locks ticket_types rows in deterministic ascending-id order internally
#   (never in the order the caller's JSON array lists them), both orders
#   must complete successfully with NO deadlock (Postgres error 40P01).
#
# How to run against a REAL local Supabase stack:
#   1. supabase start
#   2. supabase db reset      (applies all migrations, including RFC-006's)
#   3. DATABASE_URL="postgresql://postgres:postgres@127.0.0.1:54322/postgres" \
#        ./scripts/rfc-006-concurrency-test.sh
#
#   (54322 is Supabase CLI's default local Postgres port as of this
#   writing; run `supabase status` if unsure.)
#
# How to run against a plain local Postgres that already has the RFC-006
# migrations applied under a different connection (e.g. this project's own
# verification shim, used when no local Supabase/Docker is available):
#   DATABASE_URL="postgresql://postgres@/lucky_ticket_verify?host=/var/run/postgresql" \
#     ./scripts/rfc-006-concurrency-test.sh
#
# The script creates its own disposable fixtures (organization, event,
# ticket types) under a fixed, clearly-namespaced UUID prefix, runs the
# race, prints a report, and cleans its fixtures up afterwards (in a
# `trap`, so cleanup runs even if an assertion fails) - it commits real
# rows for the duration of the test, since two independent psql
# connections cannot share one uncommitted transaction. It refuses to run
# if the resolved connection looks like it might be Supabase Cloud
# (anything that isn't 127.0.0.1/localhost/a unix socket), per RFC-006
# section 70's "never run destructive testing against Cloud".

set -euo pipefail

DATABASE_URL="${DATABASE_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"

# --- Safety guard: refuse anything that isn't obviously local. -------------
case "$DATABASE_URL" in
  *127.0.0.1*|*localhost*|*"host=/var/run/postgresql"*|*"host=/tmp"*)
    ;;
  *)
    echo "REFUSING to run: DATABASE_URL does not look like a local database." >&2
    echo "  DATABASE_URL=$DATABASE_URL" >&2
    echo "This script only runs against 127.0.0.1/localhost/a unix socket," >&2
    echo "to guarantee it can never touch Supabase Cloud (RFC-006 section 70)." >&2
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

ORG_ID="06cc0000-0000-0000-0000-0000000000c1"
ORG_SLUG="rfc006-concurrency-org"
EVENT_ID="06cc0000-0000-0000-0000-0000000000c2"
EVENT_SLUG="rfc006-concurrency-show"

# Scenario 1 fixtures
GA_TT_ID="06cc0000-0000-0000-0000-0000000000c3"

# Scenario 2 fixtures (fresh ticket types so scenario 1's consumption
# doesn't interfere)
GEN2_TT_ID="06cc0000-0000-0000-0000-0000000000c4"
VIP2_TT_ID="06cc0000-0000-0000-0000-0000000000c5"

cat > "$WORKDIR/setup.sql" <<SQL
begin;
insert into public.organizations (id, name, slug, currency, timezone) values
  ('$ORG_ID', 'RFC-006 Concurrency Org', '$ORG_SLUG', 'ARS', 'America/Argentina/Buenos_Aires')
  on conflict (id) do nothing;

insert into public.events (id, organization_id, name, slug, starts_at, venue_name, status) values
  ('$EVENT_ID', '$ORG_ID', 'RFC-006 Concurrency Show', '$EVENT_SLUG', now() + interval '30 days', 'Test Venue', 'DRAFT')
  on conflict (id) do nothing;

-- Scenario 1: exactly ONE ticket available. Two concurrent buyers race for it.
insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('$GA_TT_ID', '$ORG_ID', '$EVENT_ID', 'Concurrency GA', 100000, 'ARS', 1, 'PUBLIC', true)
  on conflict (id) do nothing;

-- Scenario 2: plenty of capacity on both types; the point is lock ORDER, not scarcity.
insert into public.ticket_types (id, organization_id, event_id, name, unit_price_amount, currency, quantity, visibility, active) values
  ('$GEN2_TT_ID', '$ORG_ID', '$EVENT_ID', 'Concurrency General', 100000, 'ARS', 10, 'PUBLIC', true),
  ('$VIP2_TT_ID', '$ORG_ID', '$EVENT_ID', 'Concurrency VIP', 200000, 'ARS', 10, 'PUBLIC', true)
  on conflict (id) do nothing;

update public.events set status = 'PUBLISHED' where id = '$EVENT_ID';
commit;
SQL

cat > "$WORKDIR/teardown.sql" <<SQL
begin;
delete from public.ticket_holds where event_id = '$EVENT_ID';
delete from public.order_items where organization_id = '$ORG_ID';
delete from public.orders where organization_id = '$ORG_ID';
delete from public.customers where organization_id = '$ORG_ID';
delete from public.ticket_types where organization_id = '$ORG_ID';
delete from public.events where organization_id = '$ORG_ID';
delete from public.organizations where id = '$ORG_ID';
commit;
SQL

echo "=== RFC-006 concurrency test ==="
echo "Target: $DATABASE_URL"
echo
echo "--- Setting up fixtures ---"
"${PSQL[@]}" -f "$WORKDIR/setup.sql"

run_checkout() {
  # Exit status is written to its own file (never appended to the captured
  # stdout/stderr) so its ordering can never race against psql's own
  # (sometimes asynchronously flushed) error/CONTEXT output.
  local out_file="$1" tt_json="$2" buyer_email="$3" token_hash="$4"
  local status=0
  psql "$DATABASE_URL" -X -q -v ON_ERROR_STOP=1 \
    -c "\set VERBOSITY verbose" \
    -c "set role anon;" \
    -c "select order_id, order_status from public.create_order_with_hold('$ORG_SLUG', '$EVENT_SLUG', '$tt_json'::jsonb, 'Concurrency Buyer', '$buyer_email', null, '$token_hash');" \
    > "$out_file" 2>&1 || status=$?
  echo "$status" > "$out_file.exit"
}

# ---------------------------------------------------------------------------
# Scenario 1: capacity=1, two concurrent requests for 1 ticket each.
# ---------------------------------------------------------------------------
echo
echo "--- Scenario 1: capacity=1 race (RFC-006 section 12/59) ---"

REQ_A_JSON="[{\"ticketTypeId\": \"$GA_TT_ID\", \"quantity\": 1}]"
REQ_B_JSON="$REQ_A_JSON"

run_checkout "$WORKDIR/req_a.out" "$REQ_A_JSON" "concurrency.a@example.test" \
  "aaaaaaaa1111aaaaaaaa1111aaaaaaaa1111aaaaaaaa1111aaaaaaaa1111aaaa" &
PID_A=$!
run_checkout "$WORKDIR/req_b.out" "$REQ_B_JSON" "concurrency.b@example.test" \
  "bbbbbbbb2222bbbbbbbb2222bbbbbbbb2222bbbbbbbb2222bbbbbbbb2222bbbb" &
PID_B=$!

wait "$PID_A" || true
wait "$PID_B" || true

EXIT_A="$(cat "$WORKDIR/req_a.out.exit")"
EXIT_B="$(cat "$WORKDIR/req_b.out.exit")"

echo "Request A exit code: $EXIT_A"
sed 's/^/  [A] /' "$WORKDIR/req_a.out"
echo "Request B exit code: $EXIT_B"
sed 's/^/  [B] /' "$WORKDIR/req_b.out"

SUCCESS_COUNT=0
FAIL_COUNT=0
[ "$EXIT_A" = "0" ] && SUCCESS_COUNT=$((SUCCESS_COUNT+1)) || FAIL_COUNT=$((FAIL_COUNT+1))
[ "$EXIT_B" = "0" ] && SUCCESS_COUNT=$((SUCCESS_COUNT+1)) || FAIL_COUNT=$((FAIL_COUNT+1))

echo
echo "Successful requests: $SUCCESS_COUNT (expected: 1)"
echo "Failed requests:     $FAIL_COUNT (expected: 1)"

FAIL_HAS_LT005=0
if [ "$EXIT_A" != "0" ] && grep -q "LT005" "$WORKDIR/req_a.out"; then FAIL_HAS_LT005=1; fi
if [ "$EXIT_B" != "0" ] && grep -q "LT005" "$WORKDIR/req_b.out"; then FAIL_HAS_LT005=1; fi

ACTIVE_RESERVED="$(psql "$DATABASE_URL" -X -q -t -A -v ON_ERROR_STOP=1 -c "
  select coalesce(sum(h.quantity), 0)
  from public.ticket_holds h
  join public.orders o on o.id = h.order_id
  where h.ticket_type_id = '$GA_TT_ID'
    and o.status = 'PENDING_PAYMENT'
    and h.expires_at > now();
")"

echo "Active reserved quantity for the capacity=1 ticket type: $ACTIVE_RESERVED (expected: 1)"

SCENARIO_1_OK=1
if [ "$SUCCESS_COUNT" -ne 1 ] || [ "$FAIL_COUNT" -ne 1 ] || [ "$FAIL_HAS_LT005" -ne 1 ] || [ "$ACTIVE_RESERVED" != "1" ]; then
  SCENARIO_1_OK=0
fi

if [ "$SCENARIO_1_OK" -eq 1 ]; then
  echo "Scenario 1 RESULT: PASS - no overselling, exactly one winner, failure is a stable domain error (LT005)."
else
  echo "Scenario 1 RESULT: FAIL - see output above."
fi

# ---------------------------------------------------------------------------
# Scenario 2: overlapping multi-ticket carts, opposite lock-acquisition
# order in the JSON payload, both must succeed with no deadlock.
# ---------------------------------------------------------------------------
echo
echo "--- Scenario 2: deterministic lock ordering / deadlock check (RFC-006 section 13/60) ---"

REQ_C_JSON="[{\"ticketTypeId\": \"$GEN2_TT_ID\", \"quantity\": 1}, {\"ticketTypeId\": \"$VIP2_TT_ID\", \"quantity\": 1}]"
REQ_D_JSON="[{\"ticketTypeId\": \"$VIP2_TT_ID\", \"quantity\": 1}, {\"ticketTypeId\": \"$GEN2_TT_ID\", \"quantity\": 1}]"

run_checkout "$WORKDIR/req_c.out" "$REQ_C_JSON" "concurrency.c@example.test" \
  "cccccccc3333cccccccc3333cccccccc3333cccccccc3333cccccccc3333cccc" &
PID_C=$!
run_checkout "$WORKDIR/req_d.out" "$REQ_D_JSON" "concurrency.d@example.test" \
  "dddddddd4444dddddddd4444dddddddd4444dddddddd4444dddddddd4444dddd" &
PID_D=$!

wait "$PID_C" || true
wait "$PID_D" || true

EXIT_C="$(cat "$WORKDIR/req_c.out.exit")"
EXIT_D="$(cat "$WORKDIR/req_d.out.exit")"

echo "Order A (General, VIP) exit code: $EXIT_C"
sed 's/^/  [A] /' "$WORKDIR/req_c.out"
echo "Order B (VIP, General) exit code: $EXIT_D"
sed 's/^/  [B] /' "$WORKDIR/req_d.out"

DEADLOCK_DETECTED=0
grep -qi "deadlock" "$WORKDIR/req_c.out" && DEADLOCK_DETECTED=1
grep -qi "deadlock" "$WORKDIR/req_d.out" && DEADLOCK_DETECTED=1

SCENARIO_2_OK=1
if [ "$EXIT_C" != "0" ] || [ "$EXIT_D" != "0" ] || [ "$DEADLOCK_DETECTED" -ne 0 ]; then
  SCENARIO_2_OK=0
fi

echo
echo "Deadlock detected: $([ "$DEADLOCK_DETECTED" -eq 1 ] && echo yes || echo no) (expected: no)"
if [ "$SCENARIO_2_OK" -eq 1 ]; then
  echo "Scenario 2 RESULT: PASS - both overlapping carts succeeded, no deadlock, regardless of JSON item order."
else
  echo "Scenario 2 RESULT: FAIL - see output above."
fi

echo
echo "=== Overall ==="
if [ "$SCENARIO_1_OK" -eq 1 ] && [ "$SCENARIO_2_OK" -eq 1 ]; then
  echo "ALL SCENARIOS PASSED."
  exit 0
else
  echo "AT LEAST ONE SCENARIO FAILED."
  exit 1
fi
