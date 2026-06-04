# Migration Agent Guide

You are helping a user migrate their Heroku Postgres database to PlanetScale using this tool. This file contains everything you need to assist them: pre-checks, common errors, and troubleshooting.

## Project overview

This tool uses [sluice](https://github.com/sluicesync/sluice)'s **postgres-trigger CDC engine** to replicate data from Heroku Postgres to PlanetScale with minimal downtime. It runs as a temporary Heroku app (or Docker container) with a web dashboard. It is a fork of PlanetScale's Bucardo-based `heroku-migrator` with the replication engine swapped to sluice — same dashboard and phase model, different internals.

**Key files:**
- `entrypoint.sh` — container entry point. Sets up env/TLS, writes initial status, starts the dashboard server, and warm-resumes the sync after a dyno restart.
- `scripts/mk-sluice-repl.sh` — `--phase configure` installs the trigger engine (`sluice trigger setup`); `--phase copy` launches the long-lived `sluice sync start` process.
- `scripts/rm-sluice-repl.sh` — cleanup: stops the sync and runs `sluice trigger teardown` to remove every trace from the source.
- `scripts/stat-sluice-repl.sh` — prints schema + `sluice sync status --format=json`.
- `status-server/server.rb` — WEBrick HTTP server. All dashboard endpoints, readiness checks, and migration actions.
- `status-server/dashboard.html` — single-page dashboard UI.

**Migration phases:** `waiting → starting → configuring → ready_to_copy → copying → replicating → switched → cleaning_up → completed`. Any phase can transition to `error`.

**How the engine maps to phases:**
- `configuring` = `sluice trigger setup` on the source (installs change-log + capture function + per-table triggers; change capture begins here).
- `copying` = `sluice sync start` running its snapshot + bulk copy (schema is created on the target at the head of this phase).
- `replicating` = a CDC position row exists in `sluice_cdc_state` on the target (snapshot→CDC handoff done).

## Pre-migration checklist

Run these against the Heroku source BEFORE the user clicks Start Migration.

### 1. Extensions

```sql
SELECT extname, extversion FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;
```

Every extension must be enabled on PlanetScale first. sluice preflights extension types and refuses loudly rather than silently dropping them; enabling on the target up front avoids a setup failure.

### 2. Primary keys and unique indexes

Every table must have a primary key or unique index — sluice's trigger engine tracks rows by PK.

```sql
SELECT c.relname FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname='public' AND c.relkind='r'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND (i.indisprimary OR i.indisunique))
ORDER BY c.relname;
```

The dashboard runs this via `GET /preflight-checks` and blocks Start Migration if any table is returned.

### 3. Storage sizing

PlanetScale should have headroom over Heroku's reported "Data Size" (`heroku pg:info -a <app>`). 1.5–2× is safe; autovacuum reclaims slack after the copy.

### 4. Dyno sizing

Memory does **not** scale with data size here (no embedded PG/daemon — just a streaming Go binary). Standard-1x suffices for most databases; Standard-2x for very high write volume. You do not need Performance dynos. Watch for R14 only on pathological write rates.

### 5. Generated columns

PostgreSQL `GENERATED ALWAYS AS ... STORED` columns are handled automatically: sluice recreates them on the target and omits them from the copy; the target recomputes the value. No user action. The dashboard preflight lists affected tables for visibility.

### 6. Region matching

Heroku and PlanetScale should be in the same AWS region; cross-region adds latency to every snapshot read and CDC apply.

### 7. Fresh PlanetScale target

Always use a clean PlanetScale database/branch per attempt. Retrying against a target with leftover tables from a failed run will collide on cold-start (sluice refuses to bulk-copy into a populated target unless `--reset-target-data` is set, which this tool does not pass).

## Common errors and fixes

### "run `sluice trigger setup` before starting the stream"

The copy phase launched before the trigger engine was installed (or the change-log was removed). The `configuring` phase must complete first. Retry from `waiting`.

### Extension type not available on target

Setup or copy fails because a source extension type isn't enabled on PlanetScale. Enable the extension on the target, then **Abort**, recreate a fresh PlanetScale branch, and start again.

### Cold-start refusal: target not empty

```
refusing to bulk-copy into a non-empty target
```

The PlanetScale target already has tables/rows from a prior attempt. Use a fresh branch/database and restart.

### Initial copy restarted after a dyno restart

Expected if the restart landed during `copying`. `sluice sync start`'s initial copy is not resumable mid-table (same as Bucardo `onetimecopy`). Let it re-copy, or run the container off-Heroku for very large databases. Once in `replicating`, restarts warm-resume cleanly.

### Cutover blocked

The dashboard blocks Switch Traffic until the initial copy is finished (a CDC position exists) and replication is healthy. If `sluice sync status` shows a maintained, recent position but the UI shows a soft warning (e.g. high lag because the source is quiet), use the override on the Switch Traffic button.

## Retrieving logs

```bash
curl -u admin:<password> https://<migration-app>.herokuapp.com/logs
```

Returns JSON with:
- `setup` — output from `mk-sluice-repl.sh` (trigger setup / sync launch). Check first for setup errors.
- `sync` — tail of the `sluice sync start` process log. Check for copy/CDC errors and the snapshot→CDC handoff.

```bash
curl -u admin:<password> https://<migration-app>.herokuapp.com/status
```

Key fields:
- `phase` / `state` / `error`
- `sluice.initial_copy_phase` — `in-progress` (no position yet) or `finished`
- `sluice.last_good_sync` / `sluice.seconds_since_last_good` — freshness/lag
- `cutover_readiness.level` — `blocked` / `warning` / `ready`
- `progress_signals.byte_weighted.percent` — estimated copy progress
- `progress_signals.stall_detection.stalled`

## Diagnostic queries (Heroku source)

```sql
-- Non-default extensions
SELECT extname, extversion FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;

-- Tables without a PK / unique index
SELECT c.relname FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname='public' AND c.relkind='r'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND (i.indisprimary OR i.indisunique))
ORDER BY c.relname;

-- Leftover sluice trigger state (after a failed run)
SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'sluice_%';
SELECT to_regclass('public.sluice_change_log');
```

## Manual cleanup after a failed migration

If Abort fails or the dashboard is unreachable, tear down the trigger engine yourself with the sluice binary (it's on the dyno PATH via `heroku ps:exec`):

```bash
sluice trigger teardown --dsn "$HEROKU_URL" --yes
```

Or, as a last resort, drop the objects directly:

```sql
DO $$
DECLARE r RECORD;
BEGIN
  FOR r IN
    SELECT t.tgname, c.relname FROM pg_trigger t
    JOIN pg_class c ON c.oid = t.tgrelid
    JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE t.tgname LIKE 'sluice_%' AND n.nspname = 'public'
  LOOP
    EXECUTE format('DROP TRIGGER %I ON %I', r.tgname, r.relname);
  END LOOP;
END $$;
DROP TABLE IF EXISTS sluice_change_log;
```

Verify: `SELECT count(*) FROM pg_trigger WHERE tgname LIKE 'sluice_%';` should be `0`. Always use a fresh PlanetScale branch for the next attempt.
