# Qdrant 1.18 — Docker Compose, single-node

One `qdrant/qdrant:v1.18.2` container via Docker Compose, configured from `.env`, storage on a **host bind
mount** so it **survives `docker compose down -v`**, `restart: always`. REST `:6333` (built-in
**/dashboard** UI), gRPC `:6334`. `setup.sh` generates the API key, enforces it, and verifies enforcement.
Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates the API key, waits for `/readyz`, verifies key enforcement, prints a credentials
summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create the env + data dir and bring
it up by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the database on a bind mount
(`${DATA_ROOT}/qdrant_docker` → the image's `/qdrant/storage`) and declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/qdrant_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same collections. The *only* way to delete the data is
`setup.sh purge` (or `rm -rf ${DATA_ROOT}/qdrant_docker` by hand).

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

The shared `test.sh` needs only `curl` (already present, or it falls back to a `curlimages/curl` container) —
no extra client package.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host port / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `QDRANT_IMAGE`, `QDRANT_API_KEY`,
`QDRANT_HTTP_PORT` (host → container 6333), `QDRANT_GRPC_PORT`, `DATA_ROOT`. **Leave `QDRANT_API_KEY` empty
to auto-generate a complex (24-char) key** — `setup.sh up` fills it before `docker compose up`, shows it
once, and saves it back to `.env`. **A direct `docker compose up` needs a non-empty `QDRANT_API_KEY` in
`.env`** — the compose file declares it as `${QDRANT_API_KEY:?set in .env}` and **refuses to start** with
an empty key — so the manual path sets one explicitly. If a native Qdrant already holds `6333`, set a
different `QDRANT_HTTP_PORT` in `.env`.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                # auto-generates the API key
bash setup.sh up --key 'mykey'  # or set the API key explicitly
bash setup.sh up --gen-key      # rotate to a fresh generated key
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3): resolve the key + create the bind-mount data
dir → `docker compose up -d` → poll `/readyz` → **verify the key is enforced** (`/collections` 401/403
without the key, 200 with it). It ends with a **credentials summary** (REST URL, gRPC endpoint, API key,
`/dashboard` URL); the key is shown once and saved to `.env`. A no-flag re-run **reuses** the stored key.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET AN API KEY (compose refuses to start with an empty QDRANT_API_KEY)
cp .env.example .env
sed -i "s/^QDRANT_API_KEY=.*/QDRANT_API_KEY=ChangeMe_StrongApiKey/" .env

# 2. create the host bind-mount data dir
sudo mkdir -p /data/qdrant_docker

# 3. bring it up (stock qdrant/qdrant image — NO --build needed)
docker compose up -d

# 4. wait until /readyz answers, then verify the API key is enforced
docker compose ps
# poll until the container has started and the REST port is live (a few seconds on a fresh up)
for _ in $(seq 1 30); do curl -fsS http://127.0.0.1:6333/readyz && break; sleep 2; done   # -> all shards are ready
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6333/collections         # -> 401/403 (no key)
curl -s -o /dev/null -w '%{http_code}\n' -H 'api-key: ChangeMe_StrongApiKey' http://127.0.0.1:6333/collections   # -> 200
```

**Browser UI:** once up, open `http://<host>:6333/dashboard` and paste the API key into its **Settings**
panel — the built-in dashboard lists collections, runs vector searches, and has a raw-REST console.

## Test

The shared contract test creates a **throwaway** collection, upserts bilingual-UTF-8 points with vectors,
reads them back (count / payload / ANN search), then **deletes the collection and proves zero residue**.

### A. Scripted test

```bash
# from utility/12_Qdrant/
bash ../test.sh 03_docker_single

# or drive it explicitly (use your actual key)
QDRANT_HOST=<host> QDRANT_HTTP_PORT=6333 QDRANT_API_KEY='<your-key>' bash ../test.sh
```

### B. Manual test (raw write → read → clean-up)

```bash
KEY='<your-key>'; C="dokandar_smoke"

# 1. create a collection (4-dim, Dot distance)
curl -fsS -X PUT "http://127.0.0.1:6333/collections/${C}" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"vectors":{"size":4,"distance":"Dot"}}'

# 2. upsert 3 bilingual-UTF-8 points
curl -fsS -X PUT "http://127.0.0.1:6333/collections/${C}/points?wait=true" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"points":[
    {"id":1,"vector":[0.9,0.1,0.0,0.0],"payload":{"name":"চাল-rice"}},
    {"id":2,"vector":[0.1,0.9,0.0,0.0],"payload":{"name":"ডিম-egg"}},
    {"id":3,"vector":[0.0,0.0,0.9,0.1],"payload":{"name":"মাছ-fish"}}]}'

# 3. read back: count=3, point 1's UTF-8 payload, ANN search top hit id=1
curl -fsS -X POST "http://127.0.0.1:6333/collections/${C}/points/count" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"exact":true}'                         # -> "count":3
curl -fsS "http://127.0.0.1:6333/collections/${C}/points/1" -H "api-key: ${KEY}"  # -> "name":"চাল-rice"
curl -fsS -X POST "http://127.0.0.1:6333/collections/${C}/points/search" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"vector":[0.9,0.1,0.0,0.0],"limit":1}' # -> top "id":1

# 4. delete + prove zero residue
curl -fsS -X DELETE "http://127.0.0.1:6333/collections/${C}" -H "api-key: ${KEY}"
curl -fsS "http://127.0.0.1:6333/collections" -H "api-key: ${KEY}"               # -> ${C} no longer listed
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + /readyz + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/qdrant_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/qdrant_docker
```

## Notes

- **Browser UI:** `http://<host>:6333/dashboard` — paste the API key in its Settings panel.
- Single node = no sharding/replication / no HA — see `04_docker_cluster` for the 3-peer Raft cluster.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the 3-peer Raft HA cluster variant.
