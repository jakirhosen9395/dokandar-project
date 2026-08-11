# PostgreSQL 18 — Docker Compose, single-node

PostgreSQL 18 run as a container via Docker Compose, configured from `.env`, with data on a **host bind
mount** so it **survives `docker compose down -v`**. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates a complex password, waits for the healthcheck, enforces it via `ALTER ROLE`, prints a
credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create the env + data
dir and bring it up by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the cluster on a bind mount
(`${DATA_ROOT}/postgresql_docker` → the image's `/var/lib/postgresql` VOLUME path, with `PGDATA` in a
`pgdata/` subdir → host `${DATA_ROOT}/postgresql_docker/pgdata`) and declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/postgresql_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d --build` | recreated | **reused** (retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up --build` returns to the same data. The *only* way to delete the data is
`setup.sh purge` (or `rm -rf ${DATA_ROOT}/postgresql_docker` by hand).

## Prerequisites — install Docker (one time)

Docker isn't in the Ubuntu base repo. Install Docker Engine + the Compose plugin from Docker's official
repo (on Ubuntu 26.04 "resolute", which Docker may not publish yet, point the repo at `noble`):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
CODENAME=$(. /etc/os-release; echo "$VERSION_CODENAME")
curl -fsI "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1 || CODENAME=noble
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

To run `test.sh` from the host you also need a psql client: `sudo apt-get install -y postgresql-client-18`
(or skip it and use `docker compose exec postgres psql`).

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host port / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `DATA_ROOT`, `POSTGRES_VERSION`,
`POSTGRES_USER`, `POSTGRES_PASSWORD`, `POSTGRES_DB`, `POSTGRES_PORT` (host port → container 5432).
**Leave `POSTGRES_PASSWORD` empty to auto-generate a complex (24-char) password** — `setup.sh up` fills it
before `docker compose up`, shows it once, and saves it back to `.env`. **A direct `docker compose up`
needs a non-empty `POSTGRES_PASSWORD` in `.env`** (the image refuses to initialise an empty superuser
password), so the manual path sets one explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                              # auto-generates a complex password
bash setup.sh up --user appuser --db appdb    # name the role (first init) + create a database
bash setup.sh up --password 'MyOwnSecret'     # or set the password explicitly
bash setup.sh up --gen-password               # rotate to a fresh generated password
```

`setup.sh up` prints **numbered step output**, waits for the healthcheck, then **enforces the password via
`ALTER ROLE`** over the container's local-trust socket — so it works on a fresh *or* existing cluster, and
`--gen-password` **rotates** the live password without needing the old one. It ends with a **credentials
summary** (host, port, user, password, db, connection URL); the password is shown once and saved to
`.env`. A no-flag re-run **reuses** the stored password.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose needs a non-empty POSTGRES_PASSWORD)
cp .env.example .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. create the host bind-mount data dir (compose can also auto-create it; explicit is clearer)
sudo mkdir -p /data/postgresql_docker

# 3. bring it up (reads .env for image tag, port, user, password, db)
docker compose up -d --build

# 4. wait until healthy, then verify
docker compose ps
docker compose exec postgres psql -U postgres -d postgres -tAc 'select version();'

# 5. (optional) create an application database by hand
docker compose exec postgres createdb -U postgres -O postgres appdb
```

## Test

The shared contract test creates a throwaway `dokandar_pgtest_*` database, exercises
DDL/DML/constraints/extensions, then drops everything and proves zero residue.

### A. Scripted test

```bash
# from utility/01_PostgreSQL/
bash test.sh 03_docker_single

# or drive it explicitly (needs a psql client on the host; use your actual password)
PGHOST=127.0.0.1 PGPORT=5432 PGUSER=postgres PGPASSWORD='<your-password>' bash test.sh
```

### B. Manual test (raw write → read → clean-up)

```bash
# straight through the container (no host psql client needed)
docker compose exec postgres psql -U postgres -d postgres <<'SQL'
CREATE TABLE IF NOT EXISTS dokandar_smoke(id serial primary key, note text);
INSERT INTO dokandar_smoke(note) VALUES ('hello-চাল-dokandar');
SELECT note FROM dokandar_smoke ORDER BY id DESC LIMIT 1;   -- -> hello-চাল-dokandar
DROP TABLE dokandar_smoke;
SQL
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + pg_isready + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/postgresql_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/postgresql_docker
```

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
