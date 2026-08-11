# PostgreSQL 18 — Docker Compose, HA cluster (streaming replication)

A high-availability PostgreSQL cluster via Docker Compose: **1 primary (read-write) + 2 hot-standby
replicas (read-only)** using physical **streaming replication** with one replication slot per replica —
the same topology as the native `cluster_mode` run book, on the official `postgres:18` image. Tested on
Ubuntu 26.04.

```text
        writes                          reads (either replica)
          │                              ┌──────────────┬──────────────┐
          ▼                              ▼              ▼
   ┌────────────┐   WAL stream   ┌────────────┐   ┌────────────┐
   │ pg-primary │ ─────────────► │ pg-replica1│   │ pg-replica2│
   │   :5432 RW │  (per-slot)    │  :5433 RO  │   │  :5434 RO  │
   └────────────┘ ─────────────► └────────────┘   └────────────┘
```

Replication is **asynchronous** by default (lowest write latency). Failover is **manual** (`pg_promote`)
— deterministic, matching the run book; for automatic failover use Patroni/repmgr (a follow-on).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the superuser + replication passwords, waits for all 3 nodes healthy, enforces the password on
the primary, prints a credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands.

## How it works (and why the data survives `down -v`)

- Each node stores its cluster on a **host bind mount** at the image's `/var/lib/postgresql` VOLUME path
  (`PGDATA` in a `pgdata/` subdir): `${DATA_ROOT}/postgresql_cluster/{primary,replica1,replica2}`. There
  is **no named volume**, so `docker compose down -v` keeps all three nodes' data and they resync on `up`.
- The **primary** enables WAL streaming via `command -c` flags; `primary/initdb.d/00-replication.sh`
  creates the `replicator` role + two physical slots + the `pg_hba` replication rule (first init only).
- Each **replica** uses a custom entrypoint (`replica/entrypoint.sh`): on an empty data dir it waits for
  the primary (`depends_on: service_healthy`), runs `pg_basebackup -R -S <slot>`, embeds the streaming
  password into `primary_conninfo`, then starts as a hot standby. On restart it skips the clone and
  resumes streaming (the persisted primary slot retains the WAL gap). **Replication is fully automatic on
  `up` — there is no manual cluster-init step.**

## Prerequisites

Docker Engine + Compose plugin (see `../03_docker_single/README.md` for the install). To run `setup.sh
acceptance` / `test.sh` from the host you also need a psql client: `sudo apt-get install -y
postgresql-client-18` (or `docker compose exec pg-primary psql …`).

## Configure

```bash
cp .env.example .env        # set host ports if 5432–5434 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `POSTGRES_*`, `REPL_USER`/
`REPL_PASSWORD`, `PGDATA`, and the host ports `POSTGRES_PORT` (primary) / `PG_REPLICA1_PORT` /
`PG_REPLICA2_PORT`. **If 5432–5434 are taken on this host** (e.g. a native or single-node PostgreSQL is
already running), change all three (e.g. `5442/5443/5444`). **Leave `POSTGRES_PASSWORD` and
`REPL_PASSWORD` empty to auto-generate complex passwords** — `setup.sh up` fills them before
`docker compose up`. **A direct `docker compose up` needs both set non-empty in `.env`** (the replicas
bake `REPL_PASSWORD` into `primary_conninfo` at clone time), so the manual path sets them explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                              # auto-generates the superuser + replication passwords
bash setup.sh up --user appuser --db appdb    # name the superuser (first init) + create a database
bash setup.sh up --gen-password               # rotate the SUPERUSER password (replication stays up)
```

The first `up` initializes the primary, then each replica clones it (this is why replicas take ~30–60 s
longer to go healthy). `setup.sh up` prints **numbered step output** (1/5 … 5/5), waits for all 3 nodes
healthy, **enforces the superuser password via `ALTER ROLE` on the primary** (which replicates to the
standbys), optionally creates `--db`, and ends with a **credentials summary** (primary + both replica
endpoints, superuser + replication credentials, connection URLs). Passwords are shown once and saved to
`.env`; a no-flag re-run reuses them.

> **Password rotation — important for HA.** `--gen-password` rotates **only the superuser** (a safe live
> operation, verified to leave replication intact). The **replication password is baked into the replicas
> at clone time**, so it is generated **once** (first `up`, when empty) and **never rotated** here —
> changing it would break the running standbys. To change it, `purge` and re-create the cluster.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET BOTH passwords (compose needs them non-empty; repl pw is baked at clone)
cp .env.example .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=ChangeMe_SuperuserPass/" .env
sed -i "s/^REPL_PASSWORD=.*/REPL_PASSWORD=ChangeMe_ReplicationPass/" .env

# 2. create the three host bind-mount data dirs
sudo mkdir -p /data/postgresql_cluster/primary /data/postgresql_cluster/replica1 /data/postgresql_cluster/replica2

# 3. bring up the whole cluster (primary first; replicas auto-clone + stream — no manual init)
docker compose up -d --build

# 4. wait until all three report healthy (replicas take ~30–60s to clone on first up)
watch -n2 'docker compose ps'      # Ctrl-C once pg-primary/replica1/replica2 are all "healthy"

# 5. verify streaming replication is live (should print 2)
docker compose exec pg-primary psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM pg_stat_replication WHERE state='streaming';"
```

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh acceptance
```

Runs the run book's 5 criteria: primary shows **2 streaming standbys**, **2 active slots**, a row written
on the primary is **readable on both replicas**, and **both replicas reject writes**. Cleans up after
itself.

### B. Manual acceptance (write on primary → read on a replica → assert read-only)

```bash
# write on the PRIMARY
docker compose exec pg-primary psql -U postgres -d postgres -c \
  "CREATE TABLE IF NOT EXISTS ha_check(id serial primary key, note text); INSERT INTO ha_check(note) VALUES('replicated-চাল');"

# read it back on a REPLICA (proves streaming replication)
sleep 1
docker compose exec pg-replica1 psql -U postgres -d postgres -tAc "SELECT note FROM ha_check ORDER BY id DESC LIMIT 1;"   # -> replicated-চাল

# the replica must REJECT writes (read-only hot standby)
docker compose exec pg-replica1 psql -U postgres -d postgres -c "INSERT INTO ha_check(note) VALUES('should-fail');"       # -> ERROR: read-only transaction

# clean up
docker compose exec pg-primary psql -U postgres -d postgres -c "DROP TABLE ha_check;"
```

## Test (the shared contract test, against the primary)

### A. Scripted test

```bash
# from utility/01_PostgreSQL/
bash test.sh 04_docker_cluster
```

Reads this `.env` (`POSTGRES_PORT` = primary), creates a throwaway `dokandar_pgtest_*` database on the
primary, exercises the full contract, then drops everything and proves zero residue.

### B. Manual test (raw write → read → clean-up on the primary)

```bash
docker compose exec pg-primary psql -U postgres -d postgres <<'SQL'
CREATE TABLE IF NOT EXISTS dokandar_smoke(id serial primary key, note text);
INSERT INTO dokandar_smoke(note) VALUES ('hello-চাল-dokandar');
SELECT note FROM dokandar_smoke ORDER BY id DESC LIMIT 1;   -- -> hello-চাল-dokandar
DROP TABLE dokandar_smoke;
SQL
```

## Connection model

- **Writes → the primary** (`127.0.0.1:5432`). It is the only writable node.
- **Reads → either replica** (`:5433` / `:5434`); they reject writes. libpq apps can use a multi-host URL
  with `target_session_attrs=read-write` / `read-only` to let the driver pick the node.

## Failover (manual)

If the primary is lost, promote a replica:

```bash
# promote replica 1 to primary:
docker compose exec pg-replica1 psql -U postgres -c "SELECT pg_promote();"
docker compose exec pg-replica1 psql -U postgres -tAc "SELECT pg_is_in_recovery();"   # -> f (now primary)
# then re-point replica 2 (and your apps) at the new primary and restart it.
```

## Status / logs

```bash
bash setup.sh status        # compose ps + streaming-standby count + each replica's recovery state
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=100 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/postgresql_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the three host data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/postgresql_cluster
```

## See also

- `../README.md` — using `test.sh` across all variants.
- `../../../dependencies/03_Databases_datastores/01_PostgreSQL_18/cluster_mode/run_book.md` — the native
  (no-Docker) HA run book this mirrors, incl. synchronous replication (Appendix B) and Citus sharding (A).
