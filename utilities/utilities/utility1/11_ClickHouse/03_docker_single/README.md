# ClickHouse 26.3 LTS — Docker Compose, single-node

One `clickhouse/clickhouse-server:26.3` container run via Docker Compose, configured from `.env`, with
data on a **host bind mount** so it **survives `docker compose down -v`**, `restart: always`, HTTP `:8123`
(built-in **/play** SQL console), native TCP `:9000`. Tested on Ubuntu 26.04, local + cross-host on AWS.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates a complex password, waits for the `/ping` healthcheck, verifies the creds over HTTP,
prints a credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create the env
+ data dir and bring it up by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the database on a bind mount
(`${DATA_ROOT}/clickhouse_docker` → the image's `/var/lib/clickhouse`) and declares **no named volume at
all**, so:

| Command | Container | Data (`${DATA_ROOT}/clickhouse_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (re-attached) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same data. The *only* way to delete the data is `setup.sh purge`
(or `rm -rf ${DATA_ROOT}/clickhouse_docker` by hand).

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

`test.sh` needs **no** host packages — it uses `curl` (or a `curlimages/curl` container automatically).

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host ports / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `CH_IMAGE` (the `26.3` tag), `CLICKHOUSE_USER`,
`CLICKHOUSE_PASSWORD`, `CLICKHOUSE_HTTP_PORT` (host port → container 8123), `CLICKHOUSE_TCP_PORT`
(→ container 9000), `DATA_ROOT`. **Leave `CLICKHOUSE_PASSWORD` empty to auto-generate a complex (24-char)
password** — `setup.sh up` fills it before `docker compose up`, shows it once, and saves it back to `.env`.
**A direct `docker compose up` needs a non-empty `CLICKHOUSE_PASSWORD` in `.env`** — the compose file
declares it `${CLICKHOUSE_PASSWORD:?set in .env}` and refuses to start without it — so the manual path
sets one explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                              # auto-generates a complex password
bash setup.sh up --user default               # name the SQL user (default: default)
bash setup.sh up --password 'MyOwnSecret'     # or set the password explicitly
bash setup.sh up --gen-password               # rotate to a fresh generated password
```

`setup.sh up` (3 steps) resolves the creds (saved to `.env`), creates + chowns the bind-mount data dir to
uid `101` (the clickhouse user inside the image), `docker compose up -d`, polls the HTTP `/ping`, then
verifies `SELECT version()` over HTTP. It ends with a **credentials summary** (host, ports, user,
password, `/play` URL); the password is shown once and saved to `.env`. A no-flag re-run **reuses** the
stored password. **Browser UI:** `http://<host>:8123/play` (the built-in SQL console).

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose has ${CLICKHOUSE_PASSWORD:?} — refuses empty)
cp .env.example .env
sed -i "s/^CLICKHOUSE_PASSWORD=.*/CLICKHOUSE_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. create + chown the host bind-mount data dir (uid 101 = clickhouse inside the image)
sudo mkdir -p /data/clickhouse_docker
sudo chown -R 101:101 /data/clickhouse_docker

# 3. bring it up (reads .env for image tag, ports, user, password)
docker compose up -d

# 4. wait until healthy, then verify the creds end-to-end
docker compose ps                                              # STATUS -> healthy
curl -fsS http://127.0.0.1:8123/ping                          # -> Ok.
printf 'SELECT version()' | curl -s -u default:ChangeMe_StrongPassword \
  http://127.0.0.1:8123/ --data-binary @-                      # -> 26.3.x
```

If a native ClickHouse already holds `8123`/`9000` on this host, set different `CLICKHOUSE_HTTP_PORT` /
`CLICKHOUSE_TCP_PORT` in `.env` before bringing it up.

## Test

The shared contract test confirms connectivity + auth (`SELECT 1`), creates a **throwaway** database +
MergeTree table, inserts bilingual UTF-8 rows, reads them back, then drops everything and proves zero
residue.

### A. Scripted test

```bash
# from utility/11_ClickHouse/
bash test.sh 03_docker_single

# or drive it explicitly (use your actual password)
CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_HTTP_PORT=8123 CLICKHOUSE_USER=default CLICKHOUSE_PASSWORD='<your-password>' bash test.sh
```

### B. Manual test (raw write → read → clean-up)

```bash
# straight through the container — no host client needed
CH(){ docker compose exec -T clickhouse clickhouse-client --user default --password "$1" --multiquery; }
CH ChangeMe_StrongPassword <<'SQL'
CREATE DATABASE dokandar_smoke;
CREATE TABLE dokandar_smoke.t (id UInt64, name String) ENGINE=MergeTree ORDER BY id;
INSERT INTO dokandar_smoke.t VALUES (1,'চাল-rice'),(2,'ডিম-egg'),(3,'মাছ-fish');
SELECT count() FROM dokandar_smoke.t;                       -- -> 3
SELECT name FROM dokandar_smoke.t WHERE id=1;               -- -> চাল-rice
SELECT sum(id) FROM dokandar_smoke.t;                       -- -> 6
DROP DATABASE dokandar_smoke;
SELECT count() FROM system.databases WHERE name='dokandar_smoke';   -- -> 0 (zero residue)
SQL
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + HTTP /ping + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/clickhouse_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/clickhouse_docker
```

## Notes

- **Browser UI:** the built-in **/play** SQL console at `http://<host>:8123/play` (the image enables
  `CLICKHOUSE_DEFAULT_ACCESS_MANAGEMENT=1`, so the `default` user can log in over HTTP/TCP off-box —
  SG-fenced). Enter the user/password in the console's top-right fields.
- Single node = no replication / no HA — see `04_docker_cluster` for the 3-replica + Keeper cluster.
- The image runs as uid `101` (clickhouse); `setup.sh` (and the manual step above) chown the bind dir
  accordingly so the server can write its data.

## See also

- `../README.md` — using `test.sh` across all variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the 3-replica + embedded-Keeper HA cluster.
