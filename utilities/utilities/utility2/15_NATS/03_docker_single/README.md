# NATS JetStream 2.14 — Docker Compose, single-node

NATS JetStream 2.14 run as a container via Docker Compose, configured from `.env`, with **JetStream ON**
(`-js -sd /data`), token auth, the JetStream store on a **host bind mount** so it **survives
`docker compose down -v`**, client `:4222`, JSON monitoring `:8222`. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates the token, brings the container up, waits for `/healthz`, verifies JetStream, prints a
connection summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create the env + data dir
and bring it up by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the JetStream store on a bind mount
(`${DATA_ROOT}/nats_docker` → the container's `/data`) and declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/nats_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (streams/KV re-attach) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same streams/KV. The *only* way to delete the data is
`setup.sh purge` (or `sudo rm -rf ${DATA_ROOT}/nats_docker` by hand).

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

The shared `test.sh` needs the `nats` CLI; if it isn't on the host it falls back to the `natsio/nats-box`
image automatically (no extra install needed).

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host ports / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `NATS_IMAGE` (default `nats:2.14`),
`NATS_AUTH_TOKEN`, `NATS_CLIENT_PORT` (host port → container `4222`), `NATS_MONITOR_PORT` (host port →
container `8222`), `DATA_ROOT`. **Leave `NATS_AUTH_TOKEN` empty to auto-generate a complex (24-char)
token** — `setup.sh up` fills it before `docker compose up`, shows it once, and saves it back to `.env`.
**A direct `docker compose up` needs a non-empty `NATS_AUTH_TOKEN` in `.env`** — the compose file declares
`--auth ${NATS_AUTH_TOKEN:?set in .env}`, so it **refuses to start** with an empty token — which is why the
manual path sets one explicitly. If a native NATS already holds `4222`/`8222`, change
`NATS_CLIENT_PORT`/`NATS_MONITOR_PORT`.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                  # auto-generates the token
bash setup.sh up --token 'mytok'  # or set the token explicitly
bash setup.sh up --gen-token      # rotate to a fresh generated token
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3): resolves the token (saved to `.env`), creates
the bind-mount data dir (`chown 1000:1000` for the image's `nats` uid), `docker compose up -d`, polls
`/healthz`, then verifies JetStream (`/healthz?js-enabled-only=true`). It ends with a **connection
summary** (client URL, auth token, monitoring URL, data path); the token is shown once and saved to
`.env`. A no-flag re-run **reuses** the stored token.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A TOKEN (compose refuses to start with an empty --auth token)
cp .env.example .env
sed -i "s/^NATS_AUTH_TOKEN=.*/NATS_AUTH_TOKEN=ChangeMe_StrongToken/" .env

# 2. create the host bind-mount data dir (the image runs as uid 1000)
sudo mkdir -p /data/nats_docker
sudo chown -R 1000:1000 /data/nats_docker

# 3. bring it up (reads .env for image tag, ports, token)
docker compose up -d

# 4. wait until /healthz answers 200, then verify JetStream
docker compose ps
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8222/healthz                       # -> 200
curl -fsS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8222/healthz?js-enabled-only=true" # -> 200
```

## Test

The shared contract test confirms connectivity + JetStream, creates a **throwaway KV bucket**, puts a
bilingual UTF-8 value (`চাল-rice`), reads it back, then deletes the key + bucket and proves zero residue.

### A. Scripted test

```bash
# from utility/15_NATS/
bash test.sh 03_docker_single

# or drive it explicitly (cross-host; use your actual token)
NATS_HOST=<host> NATS_CLIENT_PORT=4222 NATS_AUTH_TOKEN='<your-token>' bash test.sh
```

### B. Manual test (raw write → read → clean-up)

```bash
# run the nats CLI from the nats-box image against the published client port
URL="nats://ChangeMe_StrongToken@127.0.0.1:4222"
NB(){ docker run --rm --network host natsio/nats-box:latest nats -s "$URL" "$@"; }

NB account info | grep -iE 'JetStream|Streams'    # connectivity + JetStream responding

NB kv add DOKTEST --replicas=1 --history=1        # throwaway KV bucket
NB kv put DOKTEST rice 'চাল-rice'
NB kv get DOKTEST rice --raw                       # -> চাল-rice

# delete the key + bucket and prove zero residue
NB kv del DOKTEST rice -f
NB kv rm  DOKTEST -f
NB kv ls | grep -q DOKTEST && echo 'RESIDUE!' || echo 'clean — zero residue'
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + /healthz + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/nats_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/nats_docker
```

## Notes

- **No browser UI** — `:8222` serves JSON monitoring (`/healthz`, `/varz`, `/jsz`); use the `nats` CLI.
- Single node = no R3 replication — see `04_docker_cluster` for the 3-node mesh.

## See also

- `../README.md` — how to use `test.sh` across all variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the Docker HA cluster (3-node mesh).
