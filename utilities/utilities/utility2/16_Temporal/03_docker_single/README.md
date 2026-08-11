# Temporal — Docker Compose single-node (dev server)

One container running the embedded **dev server** (the `temporalio/admin-tools` image bundles the
`temporal` CLI, which runs `server start-dev`) — full frontend/history/matching/worker in one process,
persisted to **SQLite** on a **host bind mount** so it **survives `docker compose down -v`**, with the
built-in Web UI. Frontend gRPC `:7233`, Web UI `:8233`. No auth (dev server). Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (creates the bind-mount dir, brings the container up, polls the frontend, verifies the server
version, prints a connection summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create
the env + data dir and bring it up by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the SQLite DB on a bind mount
(`${DATA_ROOT}/temporal_docker` → the container's `/data`, with `--db-filename /data/temporal.db`) and
declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/temporal_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same namespaces/workflows. The *only* way to delete the data is
`setup.sh purge` (or `sudo rm -rf ${DATA_ROOT}/temporal_docker` by hand).

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

No host `temporal` CLI is needed — the shared `test.sh` and the manual test below run the CLI **inside** a
throwaway `temporalio/admin-tools` container (`docker run --rm --network host`).

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit ports / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. The dev server has **no auth** — there is nothing
secret to set. Vars: `TEMPORAL_ADMINTOOLS_IMAGE` (the image that bundles the CLI/dev server),
`TEMPORAL_GRPC_PORT` (host port → container 7233), `TEMPORAL_UI_PORT` (host port → container 8233),
`DATA_ROOT`. If a native Temporal already holds `7233`/`8233` on this host, change the two ports here.

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up
```

`setup.sh up` prints **numbered step output** (1/2 … 2/2), creates the bind-mount dir
(`sudo mkdir -p ${DATA_ROOT}/temporal_docker` + `chmod 0777` — the admin-tools uid varies and SQLite needs
write), runs `docker compose up -d`, polls the frontend (`operator namespace list`), verifies the server
version (`operator cluster system`), then ends with a **connection summary** (frontend gRPC endpoint,
browser-UI URL, the host data dir).

### B. Manual install (raw docker compose)

```bash
# 1. create the env file (no password to set — the dev server has no auth)
cp .env.example .env

# 2. create the host bind-mount data dir (SQLite needs write; admin-tools uid varies)
sudo mkdir -p /data/temporal_docker
sudo chmod 0777 /data/temporal_docker

# 3. bring the container up (reads .env for the image tag + host ports)
docker compose up -d

# 4. wait until the frontend answers, then verify the server version
#    (the CLI runs inside a throwaway admin-tools container — no host temporal needed)
for _ in $(seq 1 40); do docker run --rm --network host temporalio/admin-tools:latest \
  temporal --address 127.0.0.1:7233 operator namespace list >/dev/null 2>&1 && break; sleep 2; done
docker compose ps
docker run --rm --network host temporalio/admin-tools:latest \
  temporal --address 127.0.0.1:7233 operator cluster system    # -> serverVersion ...
```

- **Browser UI:** `http://<host>:8233` (built-in dev-server Web UI — no login).

## Test

The shared contract test confirms connectivity, creates a **throwaway** `dokandar_test_*` namespace with a
bilingual-UTF-8 description (`চাল-rice`), reads it back, then **deletes the namespace and proves zero
residue**. It runs the CLI inside a `temporalio/admin-tools` container, so no host `temporal` is required.

### A. Scripted test

```bash
# from utility/16_Temporal/
bash test.sh 03_docker_single

# or point it at a host explicitly (cross-host)
TEMPORAL_HOST=<host> TEMPORAL_GRPC_PORT=7233 bash test.sh
```

### B. Manual test (raw write → read → clean-up)

```bash
# run the CLI inside an admin-tools container against the frontend on :7233
TC(){ docker run --rm --network host temporalio/admin-tools:latest temporal --address 127.0.0.1:7233 "$@"; }

TC operator namespace list                                              # connectivity
NS="dokandar_smoke_$$"
TC operator namespace create "$NS" --retention 24h --description 'চাল-rice'   # write
TC operator namespace describe "$NS" | grep -iE 'Description'           # read -> চাল-rice
TC operator namespace delete "$NS" --yes                                # delete
for _ in $(seq 1 15); do TC operator namespace describe "$NS" >/dev/null 2>&1 || { echo gone; break; }; sleep 2; done
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + frontend up-check + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/temporal_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/temporal_docker
```

## See also

- `../README.md` — using `test.sh` across all variants.
- `../01_native_single/` — the no-Docker, systemd-native dev server (same SQLite topology).
- `../04_docker_cluster/` — the PostgreSQL-backed 3-node HA cluster (this dev server is single-process, not HA).
