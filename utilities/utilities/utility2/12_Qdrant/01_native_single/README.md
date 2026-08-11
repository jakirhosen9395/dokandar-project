# Qdrant 1.18 — native single-node (no Docker)

The official Qdrant **1.18.2** static binary installed to `/usr/local/bin`, run by **systemd** as the
`qdrant` user, data under **`/data/qdrant`** (preserved on uninstall). REST `:6333` (with the built-in
**/dashboard** UI), gRPC `:6334`. `setup.sh` auto-generates an API key, enforces it on the REST/gRPC API,
and verifies enforcement. Tested on Ubuntu 26.04 (resolute).

- **What runs:** one self-contained Rust binary (`/usr/local/bin/qdrant`) under systemd — no JVM, no apt
  repo, no config file (all config is injected as `QDRANT__<SECTION>__<KEY>` env vars in the unit).
- **Data:** `${DATA_ROOT}/qdrant` (default `/data/qdrant`) with `storage/` + `snapshots/` subdirs, owned by
  `qdrant:qdrant`, and symlinked from `/var/lib/qdrant` (a compat convenience link — the unit pins the
  storage path explicitly, so data lands on `/data` regardless). Install is **non-destructive**; uninstall
  **keeps the data**.
- **Browser UI:** the built-in **/dashboard** at `http://<host>:6333/dashboard` (paste the API key in its
  Settings panel).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates the API key, prints a credentials summary); and **B. Manual** — raw copy-paste
Ubuntu commands that run the exact same steps by hand, no script. Both produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit ports / bind address / a fixed API key
```

`.env` is gitignored (it holds the real API key); only `.env.example` is committed. Key vars:
`QDRANT_API_KEY`, `QDRANT_HTTP_PORT`, `QDRANT_GRPC_PORT`, `QDRANT_HOST` (bind address, default `0.0.0.0`),
`DATA_ROOT`. **Leave `QDRANT_API_KEY` empty to auto-generate a complex (24-char) key on install** — it is
shown once and saved back to `.env`. With the script you can skip the edit entirely and pass the key as a
flag; with the manual path you choose the key yourself in the commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                # auto-generates the API key
sudo bash setup.sh install --key 'mykey'  # fixed key (else a 24-char key is generated)
sudo bash setup.sh install --gen-key      # force a fresh generated key (rotate)
```

Prints **numbered step output** (1/4 … 4/4 with ✓ ticks) and ends with a **credentials summary** — REST
URL, gRPC endpoint, the API key, the `/dashboard` URL, a curl smoke command, and the data directory. The
key is **shown once** and persisted to `.env` (chmod 600). The 4 steps: resolve the key + data dir →
download the pinned binary → write the systemd unit (ports + `QDRANT__SERVICE__API_KEY`) + start → **verify
the key is enforced** (`/collections` 401/403 without the key, 200 with it). Idempotent — **a no-flag
re-run reuses the saved key.** Key resolution: `--key` > a non-empty `QDRANT_API_KEY` in `.env` > generated.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
API key where shown. There is **no apt repo** (install the upstream binary) and **no config file** (all
config is env in the unit). Qdrant pins the storage path in the unit, so the `/var/lib/qdrant` symlink is
only a compat convenience.

```bash
# 1. create the qdrant system user + data dirs on /data (storage + snapshots), and own them
sudo useradd --system --no-create-home --shell /usr/sbin/nologin qdrant || true
sudo mkdir -p /data/qdrant/storage /data/qdrant/snapshots
sudo chown -R qdrant:qdrant /data/qdrant

# 2. (compat) point /var/lib/qdrant at /data/qdrant — convenience link, NOT load-bearing
sudo rm -rf /var/lib/qdrant && sudo ln -sfn /data/qdrant /var/lib/qdrant

# 3. download the pinned 1.18.2 static binary (x86_64, glibc) into /usr/local/bin
sudo apt-get update
sudo apt-get install -y wget curl ca-certificates
wget -qO /tmp/qdrant.tar.gz "https://github.com/qdrant/qdrant/releases/download/v1.18.2/qdrant-x86_64-unknown-linux-gnu.tar.gz"
sudo tar -xzf /tmp/qdrant.tar.gz -C /usr/local/bin qdrant && rm -f /tmp/qdrant.tar.gz
/usr/local/bin/qdrant --version

# 4. write the systemd unit — all config via QDRANT__* env (pick your own API key)
sudo tee /etc/systemd/system/qdrant.service >/dev/null <<'UNIT'
[Unit]
Description=Qdrant vector database
After=network.target
[Service]
User=qdrant
WorkingDirectory=/data/qdrant
Environment=QDRANT__STORAGE__STORAGE_PATH=/data/qdrant/storage
Environment=QDRANT__STORAGE__SNAPSHOTS_PATH=/data/qdrant/snapshots
Environment=QDRANT__SERVICE__HOST=0.0.0.0
Environment=QDRANT__SERVICE__HTTP_PORT=6333
Environment=QDRANT__SERVICE__GRPC_PORT=6334
Environment=QDRANT__SERVICE__API_KEY=ChangeMe_StrongApiKey
ExecStart=/usr/local/bin/qdrant
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT

# 5. enable + start
sudo systemctl daemon-reload
sudo systemctl enable --now qdrant

# 6. verify: service active, /readyz 200, and the API key is enforced
systemctl is-active qdrant                                                          # -> active
# wait for the REST port to bind (the daemon needs a few seconds after start)
for _ in $(seq 1 20); do curl -fsS http://127.0.0.1:6333/readyz && break; sleep 2; done   # -> all shards are ready
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:6333/collections          # -> 401/403 (no key)
curl -s -o /dev/null -w '%{http_code}\n' -H 'api-key: ChangeMe_StrongApiKey' http://127.0.0.1:6333/collections   # -> 200
```

## Test

The shared contract test creates a **throwaway** collection, upserts bilingual-UTF-8 points with vectors,
reads them back (count / payload / ANN search), then **deletes the collection and proves zero residue**.

### A. Scripted test (the shared contract test)

```bash
# from utility/12_Qdrant/  (auto-reads the API key + port from 01_native_single/.env)
bash ../test.sh 01_native_single

# or pass the connection explicitly (use your actual key)
QDRANT_HOST=<host> QDRANT_HTTP_PORT=6333 QDRANT_API_KEY='<your-key>' bash ../test.sh
```

Exits `0` and prints `RESULT: PASS` when every check passes and nothing is left behind.

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
sudo bash setup.sh status        # service + readyz + collections(api-key) + data-dir size
# manual equivalents:
systemctl is-active qdrant && curl -fsS http://127.0.0.1:6333/readyz
journalctl -u qdrant -n 80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
sudo bash setup.sh uninstall     # stop + remove binary/unit/symlink; PRESERVES /data/qdrant
sudo bash setup.sh purge         # uninstall + delete /data/qdrant (+ the qdrant user) — full wipe
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + remove the unit, binary, and compat symlink — DATA on /data is PRESERVED
sudo systemctl stop qdrant
sudo systemctl disable qdrant
sudo rm -f /etc/systemd/system/qdrant.service
sudo systemctl daemon-reload
sudo rm -f /var/lib/qdrant            # this is the symlink, not the data
sudo rm -f /usr/local/bin/qdrant

# full wipe — ALSO delete the data + the qdrant user (irreversible)
sudo rm -rf /data/qdrant
sudo userdel qdrant
```

## Notes

- Single node = no sharding/replication / no HA. For HA use `04_docker_cluster` (or the native Raft
  runbook under `dependencies/.../08_Qdrant_1.18/cluster_mode/`).
- Config is via `QDRANT__<SECTION>__<KEY>` env vars (prefix `QDRANT`, separator `__`) in the systemd unit
  — there is **no `config.yaml`** in this variant.
- `QDRANT_HOST=0.0.0.0` exposes REST/dashboard off-box (SG-fenced + api-key); set `127.0.0.1` for
  loopback only.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../03_docker_single/` — the Docker Compose single-node variant.
- `../04_docker_cluster/` — the 3-peer Raft HA cluster variant.
- `../../../dependencies/03_Databases_datastores/08_Qdrant_1.18/` — the original install scripts + the
  canonical manual-install reference these commands mirror.
