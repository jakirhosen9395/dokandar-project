# Redis 8 — Docker Compose, single-node

One `redis:8` container via Docker Compose, auth **ON** (`requirepass`, the ACL `default` user),
configured from `.env`, with data on a **host bind mount** so it **survives `docker compose down -v`**,
`restart: always`. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates a complex password, waits for the healthcheck, prints a credentials summary); and
**B. Manual** — raw `docker compose` + Ubuntu commands (create the env + data dir and bring it up by
hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the keyspace on a bind mount
(`${DATA_ROOT}/redis_docker` → the container's `/data`, AOF) and declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/redis_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same data — verified live (a marker key written before `down -v` is
still present after the next `up`). The *only* way to delete the data is `setup.sh purge` (or
`rm -rf ${DATA_ROOT}/redis_docker` by hand).

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

`test.sh` runs through the container, so you do **not** need a host `redis-cli`; if you want one anyway:
`sudo apt-get install -y redis-tools`.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host port / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `REDIS_VERSION`, `REDIS_PASSWORD`,
`REDIS_PORT` (host port → container 6379), `REDIS_MAXMEMORY`, `DATA_ROOT`. **Leave `REDIS_PASSWORD` empty
to auto-generate a complex (24-char) password** — `setup.sh up` fills it before `docker compose up`, shows
it once, and saves it back to `.env`. **A direct `docker compose up` needs a non-empty `REDIS_PASSWORD` in
`.env`** (the compose file requires it — `--requirepass ${REDIS_PASSWORD:?…}`), so the manual path sets one
explicitly. If a native Redis already holds `6379`, set a different `REDIS_PORT` (e.g. `6380`).

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                  # auto-generates a complex password
bash setup.sh up --password 'MyOwnSecret'   # or set the password explicitly
bash setup.sh up --gen-password   # rotate the password (redeploys with the new one)
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3), creates the bind-mount data dir and `chown`s it
to uid 999 (the `redis` user in the image), runs `docker compose up -d`, **waits for the healthcheck**,
verifies `PING -> PONG`, and ends with a **credentials summary** (endpoint, the `default` user, password,
connection URL). The password is shown once and saved to `.env`. A no-flag re-run **reuses** the stored
password.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose requires a non-empty REDIS_PASSWORD)
cp .env.example .env
sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. create the host bind-mount data dir + chown to uid 999 (the redis user in the image)
sudo mkdir -p /data/redis_docker
sudo chown -R 999:999 /data/redis_docker

# 3. bring it up (reads .env for image tag, host port, password, maxmemory)
docker compose up -d

# 4. wait until healthy, then verify PING -> PONG through the container (no host redis-cli needed)
docker compose ps
docker compose exec redis redis-cli -a 'ChangeMe_StrongPassword' --no-auth-warning ping   # -> PONG
```

> **No browser UI** — Redis ships no web console (use `redis-cli` / the RedisInsight desktop app).

## Test

The shared contract test creates throwaway keys under a hash-tagged prefix `{dokandar_test_<ts>}`,
exercises strings / counter / TTL / list / hash / set / sorted-set + bilingual UTF-8 (`চাল`), then deletes
them all and proves zero residue.

### A. Scripted test

```bash
# from utility/04_Redis/
bash test.sh 03_docker_single

# or drive it explicitly (any host; use your actual password + the host port you published)
bash test.sh "redis://default:<your-password>@127.0.0.1:6379"
```

### B. Manual test (raw write → read → clean-up)

```bash
# straight through the container (no host redis-cli needed)
PW='<your-password>'
docker compose exec redis redis-cli -a "$PW" --no-auth-warning set dokandar:smoke 'hello-চাল-dokandar'
docker compose exec redis redis-cli -a "$PW" --no-auth-warning get dokandar:smoke      # -> hello-চাল-dokandar
docker compose exec redis redis-cli -a "$PW" --no-auth-warning del dokandar:smoke       # -> (integer) 1
docker compose exec redis redis-cli -a "$PW" --no-auth-warning exists dokandar:smoke    # -> (integer) 0  (zero residue)
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/redis_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/redis_docker
```

## Notes

- **Browser UI:** none.
- The password is passed on the `redis-server` command line; for a hardened deploy mount a `redis.conf`
  with `requirepass` instead so it isn't visible in `docker inspect`.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the Docker Compose Redis Cluster (3 primaries + 3 replicas) variant.
