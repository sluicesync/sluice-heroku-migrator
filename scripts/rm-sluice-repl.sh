set -e

# rm-sluice-repl.sh -- the sluice analog of Bucardo's rm-bucardo-repl.sh.
#
# Tear down everything sluice installed on the PRIMARY (Heroku) database:
#   1. Stop the long-lived sync process (graceful drain, then hard kill).
#   2. `sluice trigger teardown` -- drop every per-table trigger, the capture
#      function, the change-log table, and the trigger meta table. The engine's
#      promise is to remove every trace from the source.
#
# Idempotent: safe to run after a partial/failed setup or a dyno restart that
# lost the in-memory PID. Mirrors the Bucardo script's "keep going on missing
# objects" posture.

usage() {
  printf "Usage: sh %s --primary CONNINFO --replica CONNINFO\n" "$(basename "$0")" >&2
  printf "  --primary CONNINFO   connection string for the primary (Heroku) Postgres database\n" >&2
  printf "  --replica CONNINFO   connection string for the replica (PlanetScale) Postgres database\n" >&2
  exit "$1"
}

PRIMARY="" REPLICA=""
while [ "$#" -gt 0 ]
do
  case "$1" in
  "-p"|"--primary") PRIMARY="$2"; shift 2;;
  "--primary="*) PRIMARY="$(echo "$1" | cut -d"=" -f"2-")"; shift;;
  "-r"|"--replica") REPLICA="$2"; shift 2;;
  "--replica="*) REPLICA="$(echo "$1" | cut -d"=" -f"2-")"; shift;;
  "-h"|"--help") usage 0;;
  *) usage 1;;
  esac
done
if [ -z "$PRIMARY" ] || [ -z "$REPLICA" ]; then usage 1; fi

SLUICE="${SLUICE_BIN:-sluice}"
STREAM_ID="${SLUICE_STREAM_ID:-ps_import}"
STATE_DIR="${SLUICE_STATE_DIR:-/opt/sluice/state}"
SYNC_PID_FILE="$STATE_DIR/sync.pid"

# 1. Stop the sync process. Try a graceful drain first so any in-flight change
#    batch commits and the position in sluice_cdc_state is consistent. `sync
#    stop` writes a stop signal into the target control table, so it needs the
#    target DSN (not the source).
"$SLUICE" sync stop \
  --target-driver=postgres --target="$REPLICA" \
  --stream-id="$STREAM_ID" --wait 2>/dev/null || true
if [ -f "$SYNC_PID_FILE" ]; then
  PID="$(cat "$SYNC_PID_FILE")"
  if kill -0 "$PID" 2>/dev/null; then
    kill "$PID" 2>/dev/null || true
    # Give it a moment to exit cleanly, then hard-kill if it lingers.
    for _ in 1 2 3 4 5; do
      kill -0 "$PID" 2>/dev/null || break
      sleep 1
    done
    kill -9 "$PID" 2>/dev/null || true
  fi
  rm -f "$SYNC_PID_FILE"
fi

# 2. Remove every trace of the trigger engine from the primary.
#    --yes skips the destructive-action confirmation; default drops the
#    change-log + meta tables (the "remove every trace" promise).
"$SLUICE" trigger teardown --dsn="$PRIMARY" --yes 2>&1 || true

echo "sluice replication removed from the primary."
