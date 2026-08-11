# Temporal — native single-node (dev server, no Docker)

The official **Temporal CLI** binary, run by **systemd** as `temporal server start-dev` — the full
frontend/history/matching/worker in one process, persisted to **SQLite** under `/data/temporal`, with the
built-in **Web UI**. Frontend gRPC `:7233`, Web UI `:8233`. No auth (dev server). Tested on **Ubuntu 26.04
(resolute)**.

- **What runs:** the upstream `temporal` CLI binary at `/usr/local/bin/temporal`, executed by a
  `temporal.service` systemd unit as `temporal server start-dev` (SQLite + bundled Web UI).
- **Data:** `${DATA_ROOT}/temporal` (default `/data/temporal`), the SQLite store
  (`temporal.db`). Uninstall **keeps the data**; `purge` deletes it.
- **Browser UI:** the built-in dev-server Web UI at `http://<host>:8233` (no login — dev server).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (downloads the binary, writes the unit, waits for the frontend, prints a connection summary);
and **B. Manual** — raw copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both
produce the same server.

## Files

- `setup.sh` — install / uninstall / purge / status.
- `.env.example` — copy to `.env`.

## Configure

```bash
cp .env.example .env        # optional — edit ports / bind address / namespace
```

`.env` is gitignored; only `.env.example` is committed. The dev server has **no auth** — there is nothing
secret to generate. Key vars: `DATA_ROOT`, `TEMPORAL_GRPC_PORT` (default `7233`), `TEMPORAL_UI_PORT`
(default `8233`), `TEMPORAL_BIND` (default `0.0.0.0` — exposes the frontend + UI off-box, SG-fenced; use
`127.0.0.1` for loopback only), `TEMPORAL_NAMESPACE` (default `default`).

## Install

### A. Scripted install (recommended)

```bash
cp .env.example .env
sudo bash setup.sh install
```

Prints **numbered step output** (1/4 … 4/4 with ✓ ticks) and ends with a **connection summary** — frontend
gRPC endpoint, browser-UI URL, the CLI smoke-test command, and the SQLite store path. Idempotent: creates
`/data/temporal`, downloads the Temporal CLI binary (only if not already present), creates the system
`temporal` user, writes + starts the `temporal.service` unit (`server start-dev` with SQLite + UI), then
waits for the frontend to answer (`operator namespace list`).

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. There is **no apt
repo** to add: the CLI ships as a single self-contained Go binary downloaded from `temporal.download`.

```bash
# 1. data dir for the SQLite store
sudo mkdir -p /data/temporal

# 2. download + install the Temporal CLI binary (the same archive setup.sh fetches)
sudo apt-get update -y && sudo apt-get install -y wget curl ca-certificates
wget -qO /tmp/temporal.tgz "https://temporal.download/cli/archive/latest?platform=linux&arch=amd64"
mkdir -p /tmp/tdl && tar -xzf /tmp/temporal.tgz -C /tmp/tdl
sudo install -m 0755 /tmp/tdl/temporal /usr/local/bin/temporal
rm -rf /tmp/temporal.tgz /tmp/tdl
/usr/local/bin/temporal --version

# 3. a dedicated system user owns the data dir
id temporal >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin temporal
sudo chown -R temporal:temporal /data/temporal

# 4. systemd unit — `server start-dev` (SQLite + bundled Web UI), bind 0.0.0.0, gRPC 7233 / UI 8233
sudo tee /etc/systemd/system/temporal.service >/dev/null <<'UNIT'
[Unit]
Description=Temporal dev server (start-dev)
After=network-online.target
Wants=network-online.target
[Service]
User=temporal
ExecStart=/usr/local/bin/temporal server start-dev --ip 0.0.0.0 --port 7233 --ui-ip 0.0.0.0 --ui-port 8233 --db-filename /data/temporal/temporal.db --namespace default --log-level warn
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now temporal

# 5. wait for the frontend, then verify
for _ in $(seq 1 30); do /usr/local/bin/temporal operator namespace list --address 127.0.0.1:7233 >/dev/null 2>&1 && break; sleep 2; done
systemctl is-active temporal                                            # -> active
temporal operator cluster system --address 127.0.0.1:7233              # -> serverVersion ...
temporal operator namespace list  --address 127.0.0.1:7233            # -> default
```

> The dev-server frontend speaks **gRPC only** (no plain HTTP on `:7233`) — probe it with the `temporal`
> CLI, not `curl`. The Web UI on `:8233` is plain HTTP. If `TEMPORAL_BIND=0.0.0.0`, front any non-loopback
> bind with nginx/Caddy + a network boundary; never expose `:7233`/`:8233` to the open internet.

## Test

The contract/smoke test confirms connectivity, creates a **throwaway** `dokandar_test_*` namespace with a
bilingual-UTF-8 description (`চাল-rice`), reads it back, then **deletes the namespace and proves zero
residue**. It is worker-free (it exercises the frontend + persistence via namespace CRUD).

### A. Scripted test (the shared contract test)

```bash
# from utility/16_Temporal/  (auto-reads host/port from 01_native_single/.env)
bash test.sh 01_native_single

# or point it at a host explicitly (cross-host)
TEMPORAL_HOST=<host> TEMPORAL_GRPC_PORT=7233 bash test.sh
```

Exits `0` and prints `RESULT: PASS` when the namespace is created/described/deleted with zero residue.

### B. Manual test (raw write → read → clean-up)

```bash
# 1. connectivity (a namespace list is a robust up-check)
temporal operator namespace list --address 127.0.0.1:7233

# 2. create a throwaway namespace with a UTF-8 description (--retention is required, min 24h)
NS="dokandar_smoke_$$"
temporal operator namespace create "$NS" --address 127.0.0.1:7233 --retention 24h --description 'চাল-rice'

# 3. read it back — the description round-trips UTF-8 intact
temporal operator namespace describe "$NS" --address 127.0.0.1:7233 | grep -iE 'Description'   # -> চাল-rice

# 4. delete it + prove zero residue (delete is async — describe should fail once it's gone)
temporal operator namespace delete "$NS" --address 127.0.0.1:7233 --yes
for _ in $(seq 1 15); do temporal operator namespace describe "$NS" --address 127.0.0.1:7233 >/dev/null 2>&1 || { echo "gone"; break; }; sleep 2; done
```

## Status

```bash
sudo bash setup.sh status        # service + frontend (:7233) + Web UI (:8233) + data-dir size
# manual equivalents:
systemctl is-active temporal
temporal operator namespace list --address 127.0.0.1:7233               # frontend up-check
curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8233/         # -> 200/3xx (Web UI)
```

## Uninstall

### A. Scripted uninstall

Stops + removes the unit and binary but **keeps the data** at `/data/temporal`:

```bash
sudo bash setup.sh uninstall     # stop + remove the binary/unit; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/temporal + the temporal user (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + disable, drop the unit (keeps the data on /data)
sudo systemctl disable --now temporal
sudo rm -f /etc/systemd/system/temporal.service
sudo systemctl daemon-reload

# remove the CLI binary (data on /data is NOT touched)
sudo rm -f /usr/local/bin/temporal

# full wipe — ALSO delete the SQLite store + the temporal user (irreversible)
sudo rm -rf /data/temporal
sudo userdel temporal 2>/dev/null || true
```

## See also

- `../README.md` — using `test.sh` across all install variants.
- `../03_docker_single/` — the same dev server, in a container (bind-mount SQLite store).
- `../04_docker_cluster/` — the PostgreSQL-backed 3-node HA cluster (this dev server is single-process, not HA).
- `../../../dependencies/05_Workflow_engine/01_Temporal_1.31/` — the original install scripts + the canonical
  manual-install / testing reference these commands mirror.
