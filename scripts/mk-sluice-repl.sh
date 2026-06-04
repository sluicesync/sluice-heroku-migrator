set -e

# mk-sluice-repl.sh -- the sluice analog of Bucardo's mk-bucardo-repl.sh.
#
# Two responsibilities, split to match the dashboard's two-step UX:
#
#   --phase=configure  Install the postgres-trigger engine's source-side state
#                      (change-log table, capture function, per-table triggers)
#                      on the PRIMARY (Heroku) database via `sluice trigger
#                      setup`. From this moment every INSERT/UPDATE/DELETE on the
#                      primary is captured into sluice_change_log, so no write is
#                      lost in the window between the snapshot and CDC start.
#                      This is the direct analog of Bucardo installing its
#                      triggers + bucardo schema during `bucardo add`.
#
#   --phase=copy       Launch the long-lived `sluice sync start` process. sluice
#                      creates the target schema, bulk-copies every row, creates
#                      indexes + constraints, then enters CDC -- consuming the
#                      change-log the configure phase began populating. Unlike
#                      Bucardo's separate daemon, this is a single Go process; we
#                      background it and record its PID so the dashboard can stop
#                      (pause) and relaunch (warm-resume) it.
#
# Schema copy is NOT a separate step the way it is under Bucardo (pg_dump | psql):
# `sluice sync start` lands the translated schema itself at the head of the copy
# phase. The configure phase therefore only installs triggers.

usage() {
  printf "Usage: sh %s --primary CONNINFO --replica CONNINFO --phase configure|copy [--no-initial-copy]\n" "$(basename "$0")" >&2
  printf "  --primary CONNINFO   connection string for the primary (Heroku) Postgres database\n" >&2
  printf "  --replica CONNINFO   connection string for the replica (PlanetScale) Postgres database\n" >&2
  printf "  --phase PHASE        'configure' (install triggers) or 'copy' (launch sync)\n" >&2
  printf "  --no-initial-copy    resume CDC only; skip the bulk copy (data already landed)\n" >&2
  exit "$1"
}

PRIMARY="" REPLICA="" PHASE="" NO_INITIAL_COPY=0
while [ "$#" -gt 0 ]
do
  case "$1" in
  "-p"|"--primary") PRIMARY="$2"; shift 2;;
  "--primary="*) PRIMARY="$(echo "$1" | cut -d"=" -f"2-")"; shift;;
  "-r"|"--replica") REPLICA="$2"; shift 2;;
  "--replica="*) REPLICA="$(echo "$1" | cut -d"=" -f"2-")"; shift;;
  "--phase") PHASE="$2"; shift 2;;
  "--phase="*) PHASE="$(echo "$1" | cut -d"=" -f"2-")"; shift;;
  "--no-initial-copy") NO_INITIAL_COPY=1; shift;;
  "-h"|"--help") usage 0;;
  *) usage 1;;
  esac
done
if [ -z "$PRIMARY" ] || [ -z "$REPLICA" ] || [ -z "$PHASE" ]; then usage 1; fi

SLUICE="${SLUICE_BIN:-sluice}"
STREAM_ID="${SLUICE_STREAM_ID:-ps_import}"
STATE_DIR="${SLUICE_STATE_DIR:-/opt/sluice/state}"
LOG_DIR="${SLUICE_LOG_DIR:-/var/log/sluice}"
SYNC_LOG="$LOG_DIR/sync.log"
SYNC_PID_FILE="$STATE_DIR/sync.pid"
METRICS_ADDR="${SLUICE_METRICS_ADDR:-127.0.0.1:9477}"

mkdir -p "$STATE_DIR" "$LOG_DIR"

# Enumerate the primary's public tables. The postgres-trigger engine (v1)
# requires an explicit table list for `trigger setup`; empty-list discovery is
# a follow-up upstream. We only replicate tables that have a primary key or
# unique index (the engine tracks rows by PK) -- the dashboard preflight blocks
# start otherwise, so by the time we get here the set is clean.
list_tables() {
  psql "$PRIMARY" -A -t -c "
    SELECT c.relname
    FROM pg_class c
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind = 'r'
      AND EXISTS (
        SELECT 1 FROM pg_index i
        WHERE i.indrelid = c.oid AND (i.indisprimary OR i.indisunique)
      )
    ORDER BY c.relname;" | sed '/^$/d' | paste -sd, -
}

case "$PHASE" in
"configure")
  TABLES="$(list_tables)"
  if [ -z "$TABLES" ]; then
    echo "ERROR: no replicatable tables found on the primary (need a PK or unique index)." >&2
    exit 1
  fi
  echo "Installing postgres-trigger engine state on the primary for tables: $TABLES"
  # --capture-payload=full keeps the full before/after image (optimistic
  # divergence detection on apply) -- the safe default, byte-identical to a
  # plain trigger CDC install. PK-changing UPDATEs stay correct.
  #
  # --allow-polled-fingerprint is REQUIRED on Heroku: Heroku Postgres roles are
  # never superusers and lack pg_create_event_trigger, so the engine's default
  # event-trigger-based DDL detection is refused. The polled-fingerprint
  # fallback detects schema drift by hashing the catalog instead. That's the
  # right trade here -- this tool already forbids DDL during the migration, so
  # the weaker (poll-based) DDL detection is never exercised in the happy path;
  # it only exists to halt loudly if someone breaks the "no schema changes" rule.
  "$SLUICE" trigger setup \
    --dsn="$PRIMARY" \
    --tables="$TABLES" \
    --capture-payload=full \
    --allow-polled-fingerprint
  echo "Trigger engine installed. Change capture is now active on the primary."
  ;;

"copy")
  # If a sync is already running, do nothing (idempotent relaunch guard).
  if [ -f "$SYNC_PID_FILE" ] && kill -0 "$(cat "$SYNC_PID_FILE")" 2>/dev/null; then
    echo "sync process already running (pid $(cat "$SYNC_PID_FILE"))."
    exit 0
  fi

  RESUME_FLAG=""
  if [ "$NO_INITIAL_COPY" -eq 1 ]; then
    # Warm-resume: a prior run already landed the snapshot and recorded a
    # position in sluice_cdc_state on the target. `sync start` auto-detects the
    # persisted position and resumes CDC without re-copying.
    RESUME_FLAG="--resume"
    echo "Launching sluice sync (warm resume -- skipping initial copy)..."
  else
    echo "Launching sluice sync (cold start -- schema + bulk copy + CDC)..."
  fi

  # Background the long-lived process; record its PID for stop/resume.
  # Logs stream to $SYNC_LOG which the dashboard tails via /logs.
  nohup "$SLUICE" --log-level=info sync start \
    --source-driver=postgres-trigger --source="$PRIMARY" \
    --target-driver=postgres --target="$REPLICA" \
    --stream-id="$STREAM_ID" \
    --metrics-listen="$METRICS_ADDR" \
    $RESUME_FLAG \
    >> "$SYNC_LOG" 2>&1 &
  echo $! > "$SYNC_PID_FILE"
  echo "sync started (pid $(cat "$SYNC_PID_FILE")). Tailing progress to $SYNC_LOG."
  ;;

*)
  usage 1
  ;;
esac
