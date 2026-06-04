[![Deploy to Heroku](https://www.herokucdn.com/deploy/button.svg)](https://www.heroku.com/deploy?template=https://github.com/sluicesync/sluice-heroku-migrator)

# Migrate from Heroku Postgres to PlanetScale (with sluice)

This tool helps you migrate your Heroku Postgres database to [PlanetScale](https://planetscale.com) with minimal downtime. It runs as a temporary Heroku app that copies your data and keeps both databases in sync until you're ready to cut over.

> This is a [sluice](https://github.com/sluicesync/sluice)-powered fork of PlanetScale's [heroku-migrator](https://github.com/planetscale/heroku-migrator). It keeps the same dashboard, phase model, and cutover flow, but swaps the replication engine from **Bucardo** to **sluice's postgres-trigger CDC engine**. See [How it differs from the Bucardo migrator](#how-it-differs-from-the-bucardo-migrator).

## How does it work?

This app uses [sluice](https://github.com/sluicesync/sluice), an open-source database migration and continuous-sync tool, to copy your data and keep it in sync in real time. sluice's **postgres-trigger engine** installs triggers on your Heroku tables that capture every insert, update, and delete into a change-log table; sluice snapshots your data, applies it to PlanetScale, then continuously replays the change log. When you're ready, you switch your app to PlanetScale and tear down the replication. The whole process is managed through a web dashboard.

Trigger-based capture is deliberate: it works on **every Heroku Postgres tier**, including the lower tiers (`essential-0`, `standard-0`) that don't grant the `REPLICATION` role attribute and therefore can't be migrated with logical-replication-slot tools. If your role can `CREATE TRIGGER`, this tool works.

## Before you start

There are a few things to prepare before deploying the migrator.

> **Important: do not make schema changes during the migration.** sluice's trigger engine captures changes against the table shape it sees when the triggers are installed, and it deliberately **refuses to forward DDL** mid-stream. Running `CREATE TABLE`, `ALTER TABLE`, `DROP TABLE`, or any other DDL on Heroku after the migration starts will halt replication and require a restart. Pause all schema migrations on your application (including framework auto-migrations) for the entire duration of the migration — from **Start Migration** through **Complete Migration**. If you need to ship a schema change, finish or abort the migration first.

### 1. Get your Heroku database credentials

```bash
heroku config:get DATABASE_URL -a your-app-name
```

It will look like `postgres://username:password@host:5432/dbname`. Copy this value — you'll paste it as the `HEROKU_URL` when deploying the migrator.

### 2. Create your PlanetScale database and get credentials

Follow the [PlanetScale Postgres quickstart](https://planetscale.com/docs/postgres/tutorials/planetscale-postgres-quickstart) to create a database and generate a password with the **Postgres** permission. Copy the Postgres connection string — this is your `PLANETSCALE_URL`. The Postgres permission is required for schema creation during setup, not just runtime access.

### 3. Check your Heroku Postgres extensions

sluice replicates your data and translates your schema, but it does not install Postgres extensions on the target. Make sure any extension you use on Heroku is also enabled on PlanetScale **before** starting:

```bash
heroku pg:psql -a your-app-name -c "SELECT extname, extversion FROM pg_extension WHERE extname != 'plpgsql' ORDER BY extname;"
```

sluice preflights extensions and **refuses loudly** if a source extension type isn't available on the target rather than silently dropping data. Enable each one on PlanetScale first. See the [PlanetScale extensions docs](https://planetscale.com/docs/postgres/extensions).

### 4. Make sure every table has a primary key or unique index

sluice's trigger engine identifies rows by primary key. Every replicated table needs a primary key or unique index:

```bash
heroku pg:psql -a your-app-name -c "
SELECT c.relname FROM pg_class c
JOIN pg_namespace n ON n.oid = c.relnamespace
WHERE n.nspname='public' AND c.relkind='r'
  AND NOT EXISTS (SELECT 1 FROM pg_index i WHERE i.indrelid=c.oid AND (i.indisprimary OR i.indisunique))
ORDER BY c.relname;"
```

Any table returned needs a key before you start (e.g. `ALTER TABLE t ADD PRIMARY KEY (id);`). The dashboard runs this check automatically and blocks **Start Migration** until it's clean.

### 5. Size your PlanetScale database

**Cluster size:** choose a PlanetScale cluster with similar CPU/RAM to your Heroku plan. [Resizing on PlanetScale is online](https://planetscale.com/docs/postgres/cluster-configuration) with no downtime.

**Storage:** provision headroom over what Heroku reports — Postgres disk usage varies between providers and the initial copy generates WAL. 1.5–2× the Heroku data size is a safe starting point; autovacuum reclaims the slack afterward.

### 6. Dyno sizing

Unlike the Bucardo-based migrator, this tool does **not** run an embedded PostgreSQL server or a replication daemon inside the dyno — it runs a single streaming Go binary with a bounded memory footprint (sluice flushes its copy buffer at a configurable cap, 64 MiB by default). Memory does **not** scale with your database size.

| Database size / write volume | Recommended dyno |
|---|---|
| Most databases | **Standard-1x (512 MB)** |
| Very high sustained write throughput, or you want more copy parallelism headroom | Standard-2x (1 GB) |

This is a temporary app you delete after the migration, so err toward Standard-2x if unsure — but you should not need Performance dynos the way the Bucardo migrator does for large databases.

### 7. Heroku's 24-hour restart limit

Heroku restarts every dyno at least once every 24 hours. sluice's **initial copy** is not resumable mid-table when launched via `sync start` (the same caveat the Bucardo migrator has for `onetimecopy`): if a restart lands during the initial copy, the copy restarts from the beginning. Once the initial copy finishes and replication is live, restarts are handled gracefully — the runner **warm-resumes** CDC from the last persisted position.

If your initial copy could take close to or longer than 24 hours, run the container somewhere without forced restarts (EC2, ECS, a GCP VM). It's a standard Docker image:

```bash
docker run -d \
  -e HEROKU_URL="postgres://..." \
  -e PLANETSCALE_URL="postgresql://..." \
  -e PASSWORD="your-password" \
  -p 8080:8080 \
  sluice-heroku-migrator
```

## Deploy to Heroku

Click the button at the top, or deploy manually:

```bash
git clone https://github.com/sluicesync/sluice-heroku-migrator.git
cd sluice-heroku-migrator
heroku create my-migration --stack container
heroku config:set \
  HEROKU_URL="postgres://..." \
  PLANETSCALE_URL="postgresql://..." \
  PASSWORD="choose-a-password"
git push heroku main
heroku open
```

You'll be prompted for a password (username `admin`, password is the `PASSWORD` you set).

## How the migration works

Once you open the dashboard and click **Start Migration**, the process follows these steps. The phase model is identical to the upstream Bucardo migrator.

### Step 1: Setup (`configuring` → `ready_to_copy`)

The migrator installs sluice's trigger engine on your Heroku database (`sluice trigger setup`). From this moment, every change is captured into a change-log table, so nothing is lost in the window between the snapshot and live replication. This takes a few seconds. (Your **schema** is created on PlanetScale in the next step, when the copy runs — sluice translates and lands it itself.)

### Step 2: Data sync (`copying` → `replicating`)

Click **Start Data Copy** and the migrator launches `sluice sync start`. sluice creates the target schema, bulk-copies every existing row to PlanetScale, builds indexes and constraints, then enters CDC — replaying the change log in real time. The dashboard flips to **replicating** once sluice records a CDC position on the target (its snapshot→CDC handoff signal).

Your Heroku app runs normally throughout. The **Pause Sync** button stops the sync process; sluice's triggers keep capturing changes into the change-log table while paused, and **Resume Sync** warm-resumes from the last position. As with Bucardo, pausing *during the initial copy* restarts the copy from scratch on resume — pause is safe once you reach **replicating**.

### Step 3: Switch traffic (`switched`)

When the dashboard shows your databases are in sync, click **Switch Traffic**. This:

1. Runs `REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM your_heroku_user;` so no new writes land on Heroku, then
2. Runs `sluice cutover` to prime PlanetScale's sequences/identity columns past the source's high-water mark (plus a safety margin), so post-cutover inserts don't collide on serial keys.

Then point your app at PlanetScale:

```bash
heroku config:set DATABASE_URL="your-planetscale-connection-string" -a your-app-name
```

If something goes wrong, click **Revert Switch** to `GRANT` write access back to Heroku.

### Step 4: Complete (`completed`)

Once you've verified PlanetScale, click **Complete Migration**. This stops the sync and runs `sluice trigger teardown` to remove every trigger, the capture function, and the change-log table from your Heroku database. Then delete the migration app (`heroku apps:destroy my-migration`).

## Verify cleanup completed

After **Complete Migration**, confirm sluice left nothing behind on the source:

```sql
SELECT count(*) FROM pg_trigger  WHERE tgname LIKE 'sluice_%';     -- expect 0
SELECT to_regclass('public.sluice_change_log');                    -- expect NULL
```

## Environment variables

| Variable | Required | Description |
|---|---|---|
| `HEROKU_URL` | Yes | Heroku Postgres connection URL |
| `PLANETSCALE_URL` | Yes | PlanetScale Postgres connection URL |
| `PASSWORD` | Yes | Password to access the migration dashboard |
| `SLACK_WEBHOOK_URL` | No | If set, milestone notifications are POSTed here (off by default) |
| `DISABLE_NOTIFICATIONS` | No | Set to `true` to force notifications off even if a webhook is set |
| `SLUICE_STREAM_ID` | No | sluice stream id / control-table key (default `ps_import`) |

## How it differs from the Bucardo migrator

| | Bucardo migrator | This (sluice) |
|---|---|---|
| Replication engine | Bucardo (Perl, trigger-based) | sluice postgres-trigger engine (Go, trigger-based) |
| Runs inside the dyno | embedded PostgreSQL + Bucardo daemon | one static Go binary |
| Dyno memory | scales with data size (Performance-L for >100 GB) | bounded; Standard-1x/2x regardless of data size |
| Schema copy | `pg_dump \| psql` | sluice translates + creates the schema itself |
| Generated columns | manual `customcols` workaround | handled automatically |
| Cutover sequences | not primed | `sluice cutover` primes them automatically |
| Source tiers supported | any tier with trigger create | same — works where slots are denied |

What's the same: the dashboard, the phase model (`waiting → starting → configuring → ready_to_copy → copying → replicating → switched → completed`), the REVOKE/GRANT cutover, the "no DDL during migration" rule, and the primary-key requirement.

## Local development

```bash
# Build with access to the private sluice module (BuildKit secret):
DOCKER_BUILDKIT=1 docker build \
  --secret id=gh_token,env=GH_TOKEN \
  --build-arg SLUICE_VERSION=v0.97.2 \
  -t sluice-heroku-migrator .

# Or build offline against a vendored binary at ./bin/sluice:
DOCKER_BUILDKIT=1 docker build --build-arg SLUICE_SOURCE=vendored -t sluice-heroku-migrator .

docker run -it \
  -e HEROKU_URL="postgres://user:pass@host:5432/dbname" \
  -e PLANETSCALE_URL="postgresql://user:pass@host:5432/dbname?sslmode=require" \
  -e PASSWORD="your-password" \
  -p 8080:8080 \
  sluice-heroku-migrator
```

For an agent-oriented operations guide (preflight checks, common errors, troubleshooting), see [AGENTS.md](AGENTS.md). For real-world cutover notes, see [docs/heroku-migration-field-notes.md](docs/heroku-migration-field-notes.md).

## License

Apache-2.0. Derived from PlanetScale's [heroku-migrator](https://github.com/planetscale/heroku-migrator) (also Apache-2.0).
