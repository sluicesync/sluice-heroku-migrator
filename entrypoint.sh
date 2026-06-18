#!/usr/bin/env bash
set -e

echo "=== sluice Migration Runner ==="
echo "Started at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"

# ---------------------------------------------------------------------------
# Validate required env vars
# ---------------------------------------------------------------------------
for var in HEROKU_URL PLANETSCALE_URL PASSWORD; do
  if [ -z "${!var}" ]; then
    echo "ERROR: $var environment variable is required"
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# Default TLS behavior on both URLs so operators don't have to hand-tune params.
# (Identical posture to the upstream Bucardo migrator -- engine-agnostic.)
# ---------------------------------------------------------------------------
append_param() {
  # $1 = url, $2 = key=value -- echoes url with the param appended
  case "$1" in
    *"?"*) echo "$1&$2";;
    *)     echo "$1?$2";;
  esac
}

if [[ "$HEROKU_URL" != *"sslmode="* ]]; then
  HEROKU_URL="$(append_param "$HEROKU_URL" "sslmode=require")"
  export HEROKU_URL
  echo "HEROKU_URL missing sslmode; defaulting to sslmode=require"
fi

if [[ "$PLANETSCALE_URL" != *"sslmode="* ]]; then
  PLANETSCALE_URL="$(append_param "$PLANETSCALE_URL" "sslmode=require")"
  export PLANETSCALE_URL
  echo "PLANETSCALE_URL missing sslmode; defaulting to sslmode=require"
fi

if [[ "$PLANETSCALE_URL" == *"sslmode=verify-full"* || "$PLANETSCALE_URL" == *"sslmode=verify-ca"* ]]; then
  if [[ "$PLANETSCALE_URL" != *"sslrootcert="* ]]; then
    PLANETSCALE_URL="$(append_param "$PLANETSCALE_URL" "sslrootcert=system")"
    export PLANETSCALE_URL
    echo "PLANETSCALE_URL strict sslmode detected; defaulting sslrootcert=system"
  fi
fi

# psql in this image (libpq 15) predates the `sslrootcert=system` special value
# (libpq 16+) and treats "system" as a literal filename -> every psql shell-out
# against the target would fail silently (errors -> /dev/null), which skipped the
# auto-resume below (PERSISTED_PHASE empty) and broke HAS_POSITION detection.
# sluice's own Go TLS uses PLANETSCALE_URL unchanged; only psql needs the real
# CA bundle path so verify-full still verifies.
PSQL_SSLROOTCERT="${PSQL_SSLROOTCERT:-/etc/ssl/certs/ca-certificates.crt}"
psql_safe_url() { echo "$1" | sed -E "s#sslrootcert=system#sslrootcert=${PSQL_SSLROOTCERT}#"; }
PSQL_PLANETSCALE_URL="$(psql_safe_url "$PLANETSCALE_URL")"
export PSQL_PLANETSCALE_URL

export HOME="/opt/sluice"
STATE_DIR="/opt/sluice/state"
SCRIPTS_DIR="/opt/sluice/scripts"
STREAM_ID="${SLUICE_STREAM_ID:-ps_import}"
mkdir -p "$STATE_DIR" /var/log/sluice

echo "sluice version: $(sluice --version 2>/dev/null || echo unknown)"

# ---------------------------------------------------------------------------
# Check the target for existing migration state (survives dyno restarts).
# Same _ps_migration_state table the status server maintains.
# ---------------------------------------------------------------------------
echo "Checking for existing migration state..."
PERSISTED_PHASE=""
PERSISTED_STARTED=""
PERSISTED_SWITCHED=""
PERSISTED_COMPLETED=""

STATE_ROW=$(psql "$PSQL_PLANETSCALE_URL" -A -t -c "SELECT phase, started_at, switched_at, completed_at FROM _ps_migration_state WHERE id = 1" 2>/dev/null || echo "")
if [ -n "$STATE_ROW" ]; then
  PERSISTED_PHASE=$(echo "$STATE_ROW" | cut -d'|' -f1)
  PERSISTED_STARTED=$(echo "$STATE_ROW" | cut -d'|' -f2)
  PERSISTED_SWITCHED=$(echo "$STATE_ROW" | cut -d'|' -f3)
  PERSISTED_COMPLETED=$(echo "$STATE_ROW" | cut -d'|' -f4)
  echo "Found existing migration state: phase=$PERSISTED_PHASE"
fi

# ---------------------------------------------------------------------------
# Write the initial local status.json from the persisted phase.
# ---------------------------------------------------------------------------
write_status() { printf '%s\n' "$1" > "$STATE_DIR/status.json"; }

case "$PERSISTED_PHASE" in
  "switched")
    write_status "{\"phase\":\"switched\",\"state\":\"writes_revoked\",\"message\":\"Write access revoked on Heroku. Update your app to use PlanetScale.\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\",\"switched_at\":\"${PERSISTED_SWITCHED}\"}"
    ;;
  "completed")
    write_status "{\"phase\":\"completed\",\"state\":\"cleanup_complete\",\"message\":\"Migration complete. sluice replication removed.\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\",\"completed_at\":\"${PERSISTED_COMPLETED}\"}"
    ;;
  "aborted")
    write_status "{\"phase\":\"aborted\",\"state\":\"aborted\",\"message\":\"Migration aborted. All sluice triggers have been removed from your Heroku database.\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\",\"completed_at\":\"${PERSISTED_COMPLETED}\"}"
    ;;
  "cleaning_up")
    write_status "{\"phase\":\"switched\",\"state\":\"writes_revoked\",\"message\":\"Dyno restarted during cleanup. You can re-run Complete Migration from the dashboard.\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\",\"switched_at\":\"${PERSISTED_SWITCHED}\"}"
    ;;
  "error")
    write_status "{\"phase\":\"error\",\"state\":\"setup_failed\",\"message\":\"Migration encountered an error. Check logs for details.\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\"}"
    ;;
  "ready_to_copy")
    write_status "{\"phase\":\"ready_to_copy\",\"state\":\"schema_copied\",\"message\":\"Triggers installed and capturing. Ready to start data copy.\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\"}"
    ;;
  "copying"|"replicating"|"configuring"|"starting")
    write_status "{\"phase\":\"starting\",\"state\":\"resuming\",\"message\":\"Resuming migration after restart...\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\"}"
    ;;
  *)
    write_status "{\"phase\":\"waiting\",\"state\":\"ready\",\"message\":\"Ready to start migration. Click Start Migration to begin.\",\"error\":null,\"started_at\":\"$(date -u +"%Y-%m-%dT%H:%M:%SZ")\"}"
    ;;
esac

# ---------------------------------------------------------------------------
# Start the status HTTP server immediately so Heroku sees the port bound.
# ---------------------------------------------------------------------------
echo "Starting status server on port ${PORT:-8080}..."
ruby /opt/sluice/status-server/server.rb &
STATUS_SERVER_PID=$!

# ---------------------------------------------------------------------------
# Resume the sync if a migration was mid-flight before the restart.
#   - replicating          -> warm resume CDC (--no-initial-copy)
#   - copying              -> if a position exists on the target, snapshot is
#                             done -> warm resume CDC; otherwise the snapshot was
#                             interrupted and `sync start` restarts it (same
#                             caveat as Bucardo's onetimecopy).
#   - configuring/starting -> triggers may be half-installed; restart the copy
#                             path which re-runs setup idempotently.
# ready_to_copy is intentionally NOT auto-resumed: triggers are installed and
# capturing, we just wait for the user to click Start Data Copy.
# ---------------------------------------------------------------------------
# sluice's own sluice_cdc_state row is the authoritative "replication is live"
# signal -- it exists once CDC has started and is independent of the migrator's
# _ps_migration_state wizard phase. Read it FIRST so we can safely warm-resume
# even when _ps_migration_state is empty (never persisted, or first boot after
# the psql/sslrootcert fix). It does NOT fully replace _ps_migration_state, which
# also encodes pre-copy (ready_to_copy) and post-cutover (switched/completed/
# aborted) phases sluice has no concept of -- so we still honor those.
HAS_POSITION=$(psql "$PSQL_PLANETSCALE_URL" -A -t -c "SELECT 1 FROM sluice_cdc_state WHERE stream_id = '${STREAM_ID}' LIMIT 1" 2>/dev/null || echo "")

# Phases the operator has deliberately moved past (or hasn't started): never
# auto-resume CDC into these even if a stale cdc_state row lingers.
NON_RESUMABLE_PHASE=0
case "$PERSISTED_PHASE" in
  switched|cleaning_up|completed|aborted|ready_to_copy|error) NON_RESUMABLE_PHASE=1 ;;
esac

# Resume when the wizard phase says mid-flight, OR when sluice itself has a live
# CDC position and we're not in a deliberately-terminal phase.
if [[ "$PERSISTED_PHASE" =~ ^(copying|replicating|configuring|starting)$ ]] || { [ "$NON_RESUMABLE_PHASE" = "0" ] && [ -n "$HAS_POSITION" ]; }; then
  echo "Resuming sync after restart (phase='${PERSISTED_PHASE:-unknown}', cdc_position=$([ -n "$HAS_POSITION" ] && echo present || echo none))..."

  RESUME_ARGS=""
  if [ "$PERSISTED_PHASE" = "replicating" ] || [ -n "$HAS_POSITION" ]; then
    echo "Persisted CDC position found; resuming without initial copy."
    RESUME_ARGS="--no-initial-copy"
  fi

  if sh "$SCRIPTS_DIR/mk-sluice-repl.sh" --primary "$HEROKU_URL" --replica "$PLANETSCALE_URL" --phase copy $RESUME_ARGS 2>&1 | tee "$STATE_DIR/setup.log"; then
    if [ -n "$RESUME_ARGS" ]; then
      write_status "{\"phase\":\"replicating\",\"state\":\"running\",\"message\":\"sluice replication resumed after restart.\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\"}"
    else
      write_status "{\"phase\":\"copying\",\"state\":\"initial_copy\",\"message\":\"Copy resumed after restart.\",\"error\":null,\"started_at\":\"${PERSISTED_STARTED}\"}"
    fi
    echo "Sync resumed."
  else
    ERR=$(tail -5 "$STATE_DIR/setup.log" | tr '\n' ' ' | sed 's/"/\\"/g')
    write_status "{\"phase\":\"error\",\"state\":\"resume_failed\",\"message\":\"Failed to resume sync after restart.\",\"error\":\"${ERR}\",\"started_at\":\"${PERSISTED_STARTED}\"}"
    echo "ERROR: Failed to resume sync."
  fi
fi

# ---------------------------------------------------------------------------
# Keep the container running.
# ---------------------------------------------------------------------------
echo "Migration runner is active. Visit the dashboard at :${PORT:-8080}/ to monitor progress."
wait $STATUS_SERVER_PID
