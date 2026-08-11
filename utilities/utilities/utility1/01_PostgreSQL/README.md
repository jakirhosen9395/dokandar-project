# PostgreSQL 18 — utility dependency

PostgreSQL is DOKANDAR's relational system-of-record (every SQL-owning service plus the transactional
outbox). This folder holds the four install variants plus a **shared test script** that works against
all of them.

## Layout

```text
01_PostgreSQL/
├── README.md            ← this file (how to use test.sh for every variant)
├── test.sh              ← shared contract/smoke test — works against ALL variants
├── 01_native_single/    ← native (no Docker), systemd, env-file, data in /data/postgresql   [TESTED]
├── 02_native_cluster/   ← native HA (primary + streaming replicas)                           (todo)
├── 03_docker_single/    ← Docker Compose, bind-mounted data (survives `down -v`)              [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA (primary + 2 streaming replicas)                  [TESTED]
```

Each variant folder has its own `setup.sh` / `docker-compose.yml`, `.env.example`, and `README.md`. Start
there to install. Then come back here to test.

**Each variant's `setup.sh install`/`up` auto-generates a complex (24-char) password** when `.env`'s is
empty or `--gen-password` is passed (`--password X` to set it; `--user NAME` / `--db NAME` to name the
role and create a database). It prints step-by-step status and ends with a **credentials summary**
(host / port / user / password / database / connection URL). The password is saved to that variant's
`.env` (chmod 600); a no-flag re-run **reuses** it — and `test.sh` reads it from there.

## The shared test script — `test.sh`

`test.sh` resolves a connection (libpq `PGHOST`/`PGPORT`/`PGUSER`/`PGPASSWORD`, a connection string, or a
variant `.env`), so the exact same script tests any variant — native or Docker, single or cluster. When the
host has **no `psql` client** but the target port is served by a local Docker container, it automatically
runs psql **inside Docker** — so a Docker variant needs zero host packages (see the run modes below). It:

1. creates a throwaway `dokandar_pgtest_<timestamp>` database (and a throwaway role);
2. exercises DDL, DML, bilingual UTF-8, transactions, **UNIQUE/CHECK rejection**, and the DOKANDAR
   extensions (`pg_trgm`, `cube`, `earthdistance`) with a real similarity query + a `gin_trgm_ops` index;
3. optionally verifies TCP/scram auth;
4. **drops every test object** (trap-guarded, `DROP DATABASE … WITH (FORCE)`) and **proves zero residue**;
5. prints a `PASS`/`FAIL` report (also written to `test-result.txt`) and exits non-zero on any failure.

It never touches a pre-existing database — only its own `dokandar_pgtest_*` objects.

### How to run it (works for all variants)

Pass the **variant folder** — `test.sh` reads that variant's `.env` for the connection:

```bash
bash test.sh 01_native_single     # native (no Docker)
bash test.sh 03_docker_single     # Docker Compose single-node
bash test.sh 04_docker_cluster    # Docker Compose HA cluster (connects to the primary)
bash test.sh 02_native_cluster    # once that variant exists
```

Or point it at an explicit env file, or drive it directly with libpq env vars (these **always win**):

```bash
bash test.sh ./03_docker_single/.env
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD='<your-password>' bash test.sh
```

**To test ANY PostgreSQL server**, give a **connection string** (or set `DATABASE_URL`), or save it once
in a `.env` beside this script:

```bash
bash test.sh "postgresql://postgres:yourpassword@db.example.com:5432/postgres"
DATABASE_URL='postgresql://postgres:yourpassword@host:5432/db' bash test.sh
cp .env.example .env    # then set DATABASE_URL= (or PG* vars) in it, and just:  bash test.sh
```

The connection's dbname is ignored — the test creates + drops its own throwaway `dokandar_pgtest_*`
database (the user needs CREATEDB rights and access to the `postgres` database).

With no argument it resolves, in order: explicit `PG*` env → `DATABASE_URL` → this folder's `.env` → the
first `NN_*/.env` present → defaults (`127.0.0.1:5432`).

### What it needs — two run modes (auto-selected)

The script prints its mode on the first line (`[mode=host]` or `[mode=docker via <container>]`):

- **host mode** — chosen when `psql` + `pg_isready` are on `PATH`; connects over TCP to `PGHOST:PGPORT`.
  The native `setup.sh` installs the client, so `bash test.sh 01_native_single` works out of the box. For a
  Docker variant you can `sudo apt-get install -y postgresql-client-18` to use this (preferred) mode.
- **docker mode** — chosen when there is **no host client** but a local container publishes the target port.
  Bulk DDL/DML run through `docker exec` (the container's socket), while the connectivity check and the
  TCP/scram auth assertion run through a `docker run --network host` throwaway container — so a PASS still
  proves the **published port** `127.0.0.1:${POSTGRES_PORT}` actually works, not merely the socket. This
  needs only Docker, no host packages (Linux host networking). The summary states exactly what it verified.

If neither applies (no client and no local container — e.g. a remote server), it fails fast with exit `2`
and tells you to install `postgresql-client` or to run from a host that has it.

### Reading the result

`RESULT: PASS — all test objects dropped, zero residue.` and exit `0` means every check passed and the
database is back to exactly its pre-test state. Any failure prints the failing checks and exits `1`.

## See also

- `../README.md` — the utility-dependency overview (gating tiers, install order).
- `../../dependencies/03_Databases_datastores/01_PostgreSQL_18/` — the original install scripts + the
  `cluster_mode/run_book.md` HA reference behind the `*_cluster` variants.
