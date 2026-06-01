set -e

# stat-sluice-repl.sh -- the sluice analog of Bucardo's stat-bucardo-repl.sh.
#
# Prints the primary/replica schema and the live replication status. The status
# comes from `sluice sync status --format=json`, which reads the target's
# sluice_cdc_state control table -- so it works even if the sync process is
# between restarts. The JSON shape (per cmd/sluice/status_render.go) is:
#
#   {"generated_at":..., "summary":{"count":N,...},
#    "streams":[{"stream_id":"ps_import",
#                "position":{"engine":"postgres-trigger","token":"..."},
#                "updated_at":"...","age_seconds":N}]}
#
# A stream row with a postgres-trigger position means the snapshot finished and
# CDC is live (the "replicating" phase). age_seconds is the freshness/lag signal
# -- the analog of Bucardo's "seconds since last good sync".

usage() {
  printf "Usage: sh %s --primary CONNINFO --replica CONNINFO\n" "$(basename "$0")" >&2
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
export PSQL_PAGER=""

echo >&2
echo "##############################" >&2
echo "# PRIMARY AND REPLICA SCHEMA #" >&2
echo "##############################" >&2
psql "$PRIMARY" -c '\d'
psql "$REPLICA" -c '\d'

echo >&2
echo "######################" >&2
echo "# REPLICATION STATUS #" >&2
echo "######################" >&2
"$SLUICE" sync status \
  --target-driver=postgres --target="$REPLICA" \
  --stream-id="$STREAM_ID" \
  --format=json
