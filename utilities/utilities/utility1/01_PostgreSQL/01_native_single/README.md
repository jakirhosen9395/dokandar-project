# PostgreSQL 18 — native single-node (no Docker)

The relational system-of-record for DOKANDAR. This variant installs PostgreSQL 18 **natively** on an
Ubuntu host (systemd-managed, **no Docker**), driven by an env file, with data under `/data/postgresql`
(preserved on uninstall). Tested on **Ubuntu 26.04 (resolute)**, which ships `postgresql-18` in the base
apt repo.

- **What runs:** `postgresql-18` + `postgresql-client-18` + `postgresql-contrib-18`, plus the extensions
  the fleet uses (`pg_trgm`, `cube`, `earthdistance`).
- **Data:** `${DATA_ROOT}/postgresql` (default `/data/postgresql`), symlinked from `/var/lib/postgresql`.
  Install is **non-destructive** (existing `/data` is reused, never wiped); uninstall **keeps the data**.
- **Browser UI:** none (PostgreSQL has no web console — use `psql` / DBeaver / pgAdmin).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates a complex password, prints a credentials summary); and **B. Manual** — raw
copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit port / listen address / a fixed password
```

`.env` is gitignored (it holds the real password); only `.env.example` is committed. Key vars:
`DATA_ROOT`, `POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_PORT`, `POSTGRES_LISTEN_ADDRESSES`,
`POSTGRES_DB`. **Leave `POSTGRES_PASSWORD` empty to auto-generate a complex (24-char) password on
install** — it is shown once and saved back to `.env`. With the script you can skip the edit entirely and
pass everything as flags; with the manual path you choose the password yourself in the commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                              # auto-generates a complex password
sudo bash setup.sh install --user appuser --db appdb    # name the role + create a database
sudo bash setup.sh install --password 'MyOwnSecret'     # or set the password explicitly
sudo bash setup.sh install --gen-password               # force a fresh generated password (rotate)
```

Prints **numbered step output** (1/6 … 6/6 with ✓ ticks) and ends with a **credentials summary** —
host, port, user, password, database, connection URL, and the `psql` command. The password is **shown
once** and persisted to `.env` (chmod 600). Idempotent: prepares `/data/postgresql` (preserving any
existing cluster), installs the packages + extensions, applies `listen_addresses`/`port`, sets the role
password, creates `--db` if given, and verifies a password login. **A no-flag re-run reuses the stored
password.** Password resolution: `--password` > a non-empty `POSTGRES_PASSWORD` in `.env` > auto-generated.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
password where shown. **Do the `/var/lib/postgresql` → `/data` symlink *before* `apt install`**, or the
cluster initialises on the root disk instead of `/data`.

```bash
# 1. point the data dir at /data BEFORE installing (so initdb lands on /data) — non-destructive
sudo mkdir -p /data/postgresql
sudo rm -rf /var/lib/postgresql && sudo ln -sfn /data/postgresql /var/lib/postgresql

# 2. install PostgreSQL 18 from the Ubuntu 26.04 base archive (contrib ships pg_trgm/cube/earthdistance)
sudo apt-get update -y
sudo apt-get install -y postgresql-18 postgresql-client-18 postgresql-contrib-18
sudo systemctl enable --now postgresql

# 3. set listen address + port, then restart (defaults: localhost / 5432)
sudo -u postgres psql -tAc "ALTER SYSTEM SET listen_addresses='localhost'; ALTER SYSTEM SET port=5432;"
sudo systemctl restart postgresql

# 4. set a password on the postgres superuser (enables TCP/scram login) — pick your own
sudo -u postgres psql -tAc "ALTER ROLE postgres WITH LOGIN PASSWORD 'ChangeMe_StrongPassword';"

# 5. (optional) a dedicated role + application database
sudo -u postgres psql -tAc "CREATE ROLE appuser WITH SUPERUSER LOGIN PASSWORD 'ChangeMe_StrongPassword';"
sudo -u postgres createdb -O appuser appdb

# 6. enable the DOKANDAR extensions
sudo -u postgres psql -tAc "CREATE EXTENSION IF NOT EXISTS pg_trgm; CREATE EXTENSION IF NOT EXISTS cube; CREATE EXTENSION IF NOT EXISTS earthdistance;"

# 7. verify
systemctl is-active postgresql                                          # -> active
pg_isready -h 127.0.0.1 -p 5432                                         # -> accepting connections
PGPASSWORD='ChangeMe_StrongPassword' psql -h 127.0.0.1 -p 5432 -U postgres -d postgres -tAc 'select version();'
```

> **Older Ubuntu (24.04 / 22.04):** `postgresql-18` is not in the base repo — add PGDG **before** step 2
> (PGDG has no `resolute` release, so only do this on a codename PGDG publishes):
>
> ```bash
> sudo apt-get install -y curl ca-certificates
> sudo install -d /usr/share/postgresql-common/pgdg
> sudo curl -o /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc https://www.postgresql.org/media/keys/ACCC4CF8.asc
> . /etc/os-release
> echo "deb [signed-by=/usr/share/postgresql-common/pgdg/apt.postgresql.org.asc] https://apt.postgresql.org/pub/repos/apt ${VERSION_CODENAME}-pgdg main" | sudo tee /etc/apt/sources.list.d/pgdg.list
> sudo apt-get update
> ```
>
> If you added PGDG, remove it by hand on uninstall: `sudo rm -f /etc/apt/sources.list.d/pgdg.list /usr/share/postgresql-common/pgdg/apt.postgresql.org.asc && sudo apt-get update`.

## Test

The contract/smoke test creates a throwaway `dokandar_pgtest_*` database, exercises
DDL/DML/constraints/extensions, then **drops every test object and proves zero residue**.

### A. Scripted test (the shared contract test)

```bash
# from utility/01_PostgreSQL/  (auto-reads user + the generated password from 01_native_single/.env)
bash test.sh 01_native_single

# or pass the connection explicitly (use your actual password)
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD='<your-password>' bash test.sh
```

Exits `0` and prints `RESULT: PASS` when every check passes and nothing is left behind.

### B. Manual test (raw write → read → clean-up)

```bash
# write → read round-trip, then drop the test table (zero residue)
PGPASSWORD='<your-password>' psql -h 127.0.0.1 -p 5432 -U postgres -d postgres <<'SQL'
CREATE TABLE IF NOT EXISTS dokandar_smoke(id serial primary key, note text);
INSERT INTO dokandar_smoke(note) VALUES ('hello-চাল-dokandar');
SELECT note FROM dokandar_smoke ORDER BY id DESC LIMIT 1;   -- -> hello-চাল-dokandar
DROP TABLE dokandar_smoke;
SQL

# confirm the extensions are present
sudo -u postgres psql -tAc "SELECT extname FROM pg_extension WHERE extname IN ('pg_trgm','cube','earthdistance');"
```

## Status

```bash
sudo bash setup.sh status        # service + pg_isready + version + user/db + data-dir size
# manual equivalent:
systemctl is-active postgresql && pg_isready -h 127.0.0.1 -p 5432
```

## Uninstall

### A. Scripted uninstall

Removes the packages and config/logs but **keeps the data** at `/data/postgresql`:

```bash
sudo bash setup.sh uninstall     # packages + config/logs removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/postgresql (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + drop the data symlink (keeps the data on /data)
sudo systemctl stop postgresql
sudo rm -f /var/lib/postgresql        # this is the symlink, not the data

# purge packages + config/logs (data on /data is NOT touched)
sudo apt-get purge -y 'postgresql-18*' 'postgresql-client-18*' 'postgresql-contrib-18*' postgresql-common
sudo apt-get autoremove --purge -y
sudo rm -rf /etc/postgresql /var/log/postgresql

# full wipe — ALSO delete the data (irreversible)
sudo rm -rf /data/postgresql
```

## See also

- `../../README.md` — the utility-dependency overview (gating tiers, install order).
- `../../../dependencies/03_Databases_datastores/01_PostgreSQL_18/` — the original install scripts + the
  canonical manual-install reference these commands mirror.
- `../../../dependencies/03_Databases_datastores/01_PostgreSQL_18/cluster_mode/run_book.md` — HA (primary
  and streaming replicas) reference, the basis for the sibling `02_native_cluster` variant.
