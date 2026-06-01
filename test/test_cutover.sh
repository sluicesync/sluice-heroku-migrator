#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# Local mock test for cutover readiness logic.
# Starts the status server with a fake `sluice` binary and a temp state dir,
# then exercises the readiness scenarios via curl. The fake sluice binary emits
# canned `sluice sync status --format=json` output so we can drive every
# readiness branch without a real database.
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
TEST_PORT="${TEST_PORT:-9876}"
TEST_STATE_DIR="$(mktemp -d)"
FAKE_BIN_DIR="$(mktemp -d)"
FAKE_SLUICE_OUTPUT="$TEST_STATE_DIR/sluice_status.json"

PASS=0
FAIL=0
SERVER_PID=""

cleanup() {
  if [ -n "$SERVER_PID" ] && kill -0 "$SERVER_PID" 2>/dev/null; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TEST_STATE_DIR" "$FAKE_BIN_DIR"
}
trap cleanup EXIT

# --- Helpers ----------------------------------------------------------------

log()  { printf "\033[1;34m[TEST]\033[0m %s\n" "$*"; }
pass() { PASS=$((PASS + 1)); printf "\033[1;32m  PASS\033[0m %s\n" "$*"; }
fail() { FAIL=$((FAIL + 1)); printf "\033[1;31m  FAIL\033[0m %s\n" "$*"; }

write_status() { cat > "$TEST_STATE_DIR/status.json"; }
write_sluice_output() { cat > "$FAKE_SLUICE_OUTPUT"; }

# $1=method $2=path $3=expected_http_code $4=optional body grep pattern
http_check() {
  local method="$1" path="$2" expect_code="$3" expect_body="${4:-}"
  local url="http://127.0.0.1:$TEST_PORT$path"
  local response code body
  response=$(curl -s -w "\n%{http_code}" -X "$method" "$url" 2>/dev/null)
  code=$(echo "$response" | tail -1)
  body=$(echo "$response" | sed '$d')

  if [ "$code" != "$expect_code" ]; then
    fail "$method $path → HTTP $code (expected $expect_code)"
    printf "    response: %s\n" "$body"
    return 1
  fi
  if [ -n "$expect_body" ]; then
    if echo "$body" | grep -q "$expect_body"; then
      pass "$method $path → HTTP $code, body contains '$expect_body'"
    else
      fail "$method $path → HTTP $code but body missing '$expect_body'"
      printf "    response: %s\n" "$body"
      return 1
    fi
  else
    pass "$method $path → HTTP $code"
  fi
  return 0
}

get_status_field() {
  local field="$1" body
  body=$(curl -s "http://127.0.0.1:$TEST_PORT/status" 2>/dev/null)
  echo "$body" | ruby -rjson -e '
    data = JSON.parse(STDIN.read)
    keys = ARGV[0].split(".")
    val = keys.reduce(data) { |d, k| d.is_a?(Hash) ? d[k] : nil }
    puts val.to_s
  ' "$field" 2>/dev/null
}

now_iso() { ruby -rtime -e "puts Time.now.utc.iso8601"; }

# A streams[] JSON doc with one ps_import stream that has a CDC position.
# $1 = age_seconds (freshness). A present position means the snapshot finished.
sluice_status_with_position() {
  local age="$1" updated
  updated=$(ruby -rtime -e "puts (Time.now.utc - ARGV[0].to_i).iso8601" "$age")
  cat <<EOF
{"generated_at":"$(now_iso)","summary":{"count":1,"oldest_seconds":$age,"newest_seconds":$age},"streams":[{"stream_id":"ps_import","position":{"engine":"postgres-trigger","token":"42"},"updated_at":"$updated","age_seconds":$age}]}
EOF
}

# A streams[] JSON doc with no stream row -- snapshot not finished yet.
sluice_status_no_position() {
  echo '{"generated_at":"'"$(now_iso)"'","summary":{"count":0,"oldest_seconds":0,"newest_seconds":0},"streams":[]}'
}

# --- Create fake sluice + psql binaries -------------------------------------

cat > "$FAKE_BIN_DIR/sluice" << 'FAKE_SLUICE'
#!/bin/sh
# Ignore args; emit the canned status doc the test wrote.
if [ -f "$FAKE_SLUICE_OUTPUT" ]; then
  cat "$FAKE_SLUICE_OUTPUT"
else
  echo ""
fi
FAKE_SLUICE
chmod +x "$FAKE_BIN_DIR/sluice"

# Fake psql that always fails (so the switch-traffic REVOKE fails predictably).
cat > "$FAKE_BIN_DIR/psql" << 'FAKE_PSQL'
#!/bin/sh
echo "fake psql: $*" >&2
exit 1
FAKE_PSQL
chmod +x "$FAKE_BIN_DIR/psql"

# --- Start the server -------------------------------------------------------

log "Starting test server on port $TEST_PORT..."

export TEST_STATE_DIR
export FAKE_SLUICE_OUTPUT
export PORT="$TEST_PORT"
export PASSWORD="test"
export DISABLE_AUTH="true"
export DISABLE_NOTIFICATIONS="true"
export HEROKU_URL="postgres://fakeuser:fakepass@localhost:5432/fakedb"
export PLANETSCALE_URL=""
export PATH="$FAKE_BIN_DIR:$PATH"

ruby "$SCRIPT_DIR/test_server_wrapper.rb" &
SERVER_PID=$!

for i in $(seq 1 30); do
  curl -s "http://127.0.0.1:$TEST_PORT/health" >/dev/null 2>&1 && break
  sleep 0.5
done
if ! curl -s "http://127.0.0.1:$TEST_PORT/health" >/dev/null 2>&1; then
  echo "ERROR: Server failed to start"
  exit 1
fi
log "Server running (PID $SERVER_PID)"
echo ""

REPLICATING_STATUS='{"phase":"replicating","state":"running","message":"Replicating","error":null,"started_at":"2026-01-01T00:00:00Z"}'

# === SCENARIO 1: blocked - initial copy not finished (no CDC position) =======
log "Scenario 1: Cutover blocked - initial copy not finished"
echo "$REPLICATING_STATUS" | write_status
sluice_status_no_position | write_sluice_output
http_check POST /switch-traffic 409 "cutover_blocked"

# === SCENARIO 2: warning - replication lag high (position, stale) ===========
log "Scenario 2: Cutover warning - replication lag high"
echo "$REPLICATING_STATUS" | write_status
sluice_status_with_position 600 | write_sluice_output
http_check POST /switch-traffic 409 "cutover_override_required"

# === SCENARIO 3: warning + force override passes the readiness gate ==========
log "Scenario 3: Cutover warning with force override"
# Same high-lag fixture as scenario 2. force=1 should pass the gate; the REVOKE
# then fails (fake psql) but must NOT be one of the readiness block codes.
response=$(curl -s -w "\n%{http_code}" -X POST "http://127.0.0.1:$TEST_PORT/switch-traffic?force=1" 2>/dev/null)
body=$(echo "$response" | sed '$d')
if echo "$body" | grep -q "cutover_blocked\|cutover_override_required"; then
  fail "POST /switch-traffic?force=1 still blocked by readiness"
  printf "    response: %s\n" "$body"
else
  pass "POST /switch-traffic?force=1 passed readiness gate"
fi

# === SCENARIO 4: ready - fresh CDC position =================================
log "Scenario 4: Cutover ready - fresh position"
echo "$REPLICATING_STATUS" | write_status
sluice_status_with_position 5 | write_sluice_output
level=$(get_status_field "cutover_readiness.level")
if [ "$level" = "ready" ]; then
  pass "GET /status → cutover_readiness.level=ready"
else
  fail "GET /status → cutover_readiness.level=$level (expected ready)"
fi

# === SCENARIO 5: copying auto-transitions to replicating on position ========
log "Scenario 5: copying → replicating once a CDC position exists"
echo '{"phase":"copying","state":"initial_copy","message":"Copying","error":null,"started_at":"2026-01-01T00:00:00Z"}' | write_status
sluice_status_with_position 5 | write_sluice_output
phase=$(get_status_field "phase")
if [ "$phase" = "replicating" ]; then
  pass "GET /status auto-transitioned copying → replicating"
else
  fail "GET /status phase=$phase (expected replicating)"
fi

# === SCENARIO 6: retry from error resets to waiting =========================
log "Scenario 6: Retry from error state"
echo '{"phase":"error","state":"setup_failed","message":"Setup failed","error":"boom","started_at":"2026-01-01T00:00:00Z"}' | write_status
http_check POST /retry 200 '"success":true'
sleep 0.3
phase=$(get_status_field "phase")
if [ "$phase" = "waiting" ]; then
  pass "After retry, phase=waiting"
else
  fail "After retry, phase=$phase (expected waiting)"
fi

# === SCENARIO 7: retry blocked from non-error phase =========================
log "Scenario 7: Retry blocked from non-error phase"
echo "$REPLICATING_STATUS" | write_status
sluice_status_with_position 5 | write_sluice_output
http_check POST /retry 409

# === Summary ================================================================
echo ""
echo "========================================"
printf "Results: \033[1;32m%d passed\033[0m, \033[1;31m%d failed\033[0m\n" "$PASS" "$FAIL"
echo "========================================"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
