# Heroku Migration Field Notes

These notes collect production cutover issues that are easy to miss when moving
an application from Heroku Postgres to PlanetScale Postgres with the migrator.
They are not required for every migration, but they are worth reviewing before a
production cutover. Most of this is engine-agnostic Heroku/PlanetScale wisdom and
applies whether you migrate with sluice or any other tool.

## Heroku DATABASE_URL can be an attachment alias

On Heroku apps with a Heroku Postgres add-on, `DATABASE_URL` may be owned by the
add-on attachment. In that state it is not a normal config var, and this command
can fail:

```bash
heroku config:set DATABASE_URL="postgresql://..." -a your-app-name
# Cannot overwrite attachment values DATABASE_URL.
```

Before cutover, check the app's add-ons and attachment names (`heroku addons -a
your-app-name`). If `DATABASE_URL` is still owned by the Heroku Postgres add-on,
preserve access to the old database under another attachment name before
replacing `DATABASE_URL`:

```bash
# Keep an alternate URL for the old Heroku Postgres database.
heroku addons:attach <heroku-postgres-addon-name> --as HEROKU_POSTGRESQL_OLD -a your-app-name
# Detach the attachment that owns DATABASE_URL, often named DATABASE.
heroku addons:detach <database-attachment-name> -a your-app-name
# Now set DATABASE_URL to PlanetScale.
heroku config:set DATABASE_URL="postgresql://..." -a your-app-name
```

Do not discover this during the write-blocked cutover window. Rehearse the
attachment plan before clicking **Switch Traffic**.

## Use maintenance mode during cutover

The migrator's **Switch Traffic** action blocks writes on the Heroku source by
revoking write privileges. It does not update your app config, restart dynos, or
verify that all app processes are using PlanetScale.

```bash
heroku maintenance:on -a your-app-name
# Click Switch Traffic in the migrator.
# Update DATABASE_URL and any database-specific config.
heroku restart -a your-app-name
# Run app smoke tests.
heroku maintenance:off -a your-app-name
```

## Test application drivers, not only psql

PlanetScale Postgres connection strings can include libpq-style SSL query
parameters (`sslmode=verify-full`, `sslrootcert=...`, `sslnegotiation=direct`).
libpq-based clients (`psql`, psycopg) understand them; other drivers may not.
Apps using `asyncpg` through SQLAlchemy can fail if the URL is converted to
`postgresql+asyncpg://` without translating the SSL config:

```text
TypeError: connect() got an unexpected keyword argument 'sslmode'
```

Before cutover, smoke-test every app database path: web, worker, sync, async,
and migration/admin commands. If one driver can't parse the PlanetScale URL,
switch that path to a libpq-compatible driver or translate the SSL config.

## Heroku CA bundle path

`sslrootcert=system` can work in one client and fail in another depending on the
libpq/driver version. On Debian-based Heroku runtimes, the explicit CA bundle
path is often safer for application config:

```text
sslrootcert=/etc/ssl/certs/ca-certificates.crt
```

(The migrator's entrypoint already applies `sslrootcert=system` for sluice's own
connections when you request strict `sslmode`; this note is about your *app's*
runtime config after cutover.)

## Prefer pooled app connections after cutover

PlanetScale direct Postgres connections have a connection ceiling. Production
apps with multiple dynos and ORM pools can exhaust direct connections quickly.
Use the pooled PgBouncer connection string for runtime app traffic when
available; keep direct connections for migrations/admin. Watch app logs for
`too many clients` / `remaining connection slots are reserved` and reduce pool
sizes if they appear.

## Clean up old source database objects

sluice reads your source schema through its typed IR before it copies anything.
Abandoned schemas, stale tables, or rows with invalid encoding in rarely used
tables can cause the schema read or the snapshot to fail. Unlike a tool that
silently skips problems, sluice **refuses loudly** — which is safer, but means
you want to find these before you start.

Inspect non-system schemas before setup:

```sql
SELECT nspname FROM pg_namespace
WHERE nspname NOT LIKE 'pg_%' AND nspname <> 'information_schema'
ORDER BY nspname;
```

Clean up abandoned temporary/staging schemas only after confirming they're truly
unused. If a stale object causes setup to fail and you abort, start the next
attempt with a **fresh PlanetScale target** — sluice refuses to cold-copy into a
non-empty target, so a partially written branch will block a retry.

## Verify schema-dependent application objects

sluice translates and recreates your schema on the target itself (it does not
shell out to `pg_dump`). Ordinary tables, indexes, constraints, sequences, and
generated columns come across automatically. Objects that live outside the
table/index model — user-defined functions, views with engine-specific bodies,
extension-backed objects — are worth verifying on PlanetScale before cutover:

```sql
SELECT n.nspname, p.proname FROM pg_proc p
JOIN pg_namespace n ON n.oid = p.pronamespace
WHERE n.nspname NOT IN ('pg_catalog', 'information_schema')
ORDER BY n.nspname, p.proname;
```

`sluice schema diff` (run out-of-band against source and target) is a quick way
to spot translation drift before you flip traffic.

## Sequences at cutover

sluice's **Switch Traffic** runs `sluice cutover` after revoking writes, which
re-reads each source sequence's high-water mark and advances the corresponding
PlanetScale sequence past it (plus a safety margin). This prevents post-cutover
inserts from colliding on serial/identity keys — a step you'd otherwise do by
hand. If you ever need to re-run it manually:

```bash
sluice cutover \
  --source-driver=postgres --source "$HEROKU_URL" \
  --target-driver=postgres --target "$PLANETSCALE_URL"
```

## Generated columns

PostgreSQL `GENERATED ALWAYS AS ... STORED` columns are handled automatically:
sluice recreates the generation expression on the target and omits the column
from the bulk copy, so PlanetScale recomputes the value on insert. No manual
workaround is required.
