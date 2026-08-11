# ScyllaDB 2026.1 — native single-node (no Docker)

DOKANDAR's **wide-column store** — the write-heavy risk/velocity event stream behind the `18-risk-trust`
service. This variant installs ScyllaDB 2026.1 from the **official ScyllaDB apt repo** (the repo descriptor
is codename-independent, so it installs on Ubuntu 26.04 "resolute"), run by **systemd** (`scylla-server`),
data under **`/data/scylla`** (symlinked from `/var/lib/scylla`, preserved on uninstall), CQL on `:9042`.
It runs in **developer mode** (`scylla_dev_mode_setup --developer-mode 1`) so it starts **without** the
invasive `scylla_setup` host tuning a shared box can't accept. ScyllaDB ships with the **authenticator off**
(no username/password) and has **no browser UI** — interact via **`cqlsh`** / **`nodetool`**.

- **What runs:** the `scylla` package (server + `cqlsh` + `nodetool`) from the official ScyllaDB apt repo.
- **Data:** `${DATA_ROOT}/scylla` (default `/data/scylla`), symlinked from `/var/lib/scylla`. Install is
  **non-destructive** (existing `/data` is reused); uninstall **keeps the data**, `purge` deletes it.
- **Browser UI:** none (ScyllaDB has no web console — use `cqlsh` / `nodetool`).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (handles the repo key, developer mode, `scylla.yaml`, and prints a connection summary); and
**B. Manual** — raw copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both
produce the same single node.

## Configure

```bash
cp .env.example .env        # optional — edit cluster name / CQL port / RPC bind
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `SCYLLA_CLUSTER_NAME` (default
`dokandar`), `SCYLLA_CQL_PORT` (default `9042`), `SCYLLA_RPC_ADDRESS` (default `0.0.0.0` — exposes CQL
off-box, SG-fenced; `127.0.0.1` = loopback only), `DATA_ROOT` (default `/data`). There is **no password to
set** — ScyllaDB's authenticator is off by default. `setup.sh` derives `SCYLLA_LISTEN_ADDRESS` from
`hostname -I` and, when `SCYLLA_RPC_ADDRESS` is a wildcard (`0.0.0.0`), sets `broadcast_rpc_address` to that
listen IP (Scylla refuses to start with a wildcard `rpc_address` otherwise).

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks) and ends with a **connection summary** — CQL
endpoint, cluster name, the `Auth: none` note, the `cqlsh` smoke command, and the data directory. Idempotent
(5 steps): prepares `/data/scylla` and the `/var/lib/scylla` symlink → adds the official ScyllaDB apt repo
(correct **exported** signing key) + installs `scylla` → runs `scylla_dev_mode_setup --developer-mode 1` +
writes `scylla.yaml` (cluster name, listen/rpc, **`broadcast_rpc_address`**) → starts `scylla-server` and
polls for CQL → verifies `release_version`.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. **Do the
`/var/lib/scylla` → `/data` symlink *before* `apt install`**, so the data dir lands on `/data`. ScyllaDB is
**not** in the Ubuntu base repo; you add its official apt repo first.

```bash
# 1. point the data dir at /data BEFORE installing (so Scylla writes to /data) — non-destructive
sudo mkdir -p /data/scylla
sudo rm -rf /var/lib/scylla && sudo ln -sfn /data/scylla /var/lib/scylla

# 2. add the official ScyllaDB apt repo. The signing key is C503C686B007F39E and must be EXPORTED as a
#    binary keyring — apt's `signed-by` REJECTS a gpg keybox ("unsupported filetype"). The .list itself is
#    CODENAME-INDEPENDENT (debian-ubuntu/scylladb-<ver> stable main), so it works on resolute.
sudo apt-get update -y
sudo apt-get install -y wget gnupg curl ca-certificates apt-transport-https
sudo mkdir -p /etc/apt/keyrings
install -d -m 700 /tmp/scygpg
GNUPGHOME=/tmp/scygpg gpg --batch --keyserver hkp://keyserver.ubuntu.com:80 --recv-keys C503C686B007F39E
GNUPGHOME=/tmp/scygpg gpg --batch --export C503C686B007F39E | sudo tee /etc/apt/keyrings/scylladb.gpg >/dev/null
rm -rf /tmp/scygpg
sudo wget -qO /etc/apt/sources.list.d/scylla.list "http://downloads.scylladb.com/deb/ubuntu/scylla-2026.1.list"
sudo apt-get update -y
sudo apt-get install -y scylla

# 3. developer mode (skip the invasive scylla_setup host tuning so it runs on a shared box)
sudo scylla_dev_mode_setup --developer-mode 1
id scylla >/dev/null 2>&1 && sudo chown -R scylla:scylla /data/scylla

# 4. configure /etc/scylla/scylla.yaml (cluster name, listen/rpc, port, seeds, broadcast_rpc_address)
LISTEN_IP="$(hostname -I | awk '{print $1}')"; RPC_ADDR=0.0.0.0
Y=/etc/scylla/scylla.yaml
sudo sed -i "s/^cluster_name:.*/cluster_name: 'dokandar'/"            "$Y"
sudo sed -i "s/^listen_address:.*/listen_address: ${LISTEN_IP}/"      "$Y"
sudo sed -i "s/^rpc_address:.*/rpc_address: ${RPC_ADDR}/"             "$Y"
sudo sed -i "s/^native_transport_port:.*/native_transport_port: 9042/" "$Y"
sudo sed -i "s/^\(\s*\)- seeds:.*/\1- seeds: \"${LISTEN_IP}\"/"        "$Y"
# Scylla REFUSES to start with rpc_address=0.0.0.0 unless broadcast_rpc_address (the IP gossiped to
# clients) is set — point it at this node's reachable IP.
sudo sed -i "/^broadcast_rpc_address:/d" "$Y"
echo "broadcast_rpc_address: ${LISTEN_IP}" | sudo tee -a "$Y" >/dev/null

# 5. start the service and wait for CQL
sudo systemctl enable scylla-server
sudo systemctl restart scylla-server
until cqlsh "${LISTEN_IP}" 9042 -e "SELECT now() FROM system.local;" >/dev/null 2>&1; do sleep 3; done

# 6. verify
systemctl is-active scylla-server                                    # -> active
nodetool status                                                      # -> one UN (Up/Normal) node
cqlsh "${LISTEN_IP}" 9042 -e "SELECT release_version FROM system.local;"
```

> **Note on `scylla_setup`.** The deps-layer native install runs the full interactive `scylla_setup` (disk
> tuning, I/O scheduler, AIO/NIC affinity) — that path is **RECORD-ONLY** on shared boxes. This utility
> deliberately uses `scylla_dev_mode_setup --developer-mode 1` instead, which **skips** that host tuning so
> a single node comes up on any host (relaxed durability/perf — not a production tuning).

## Test

The shared contract test creates a throwaway `dokandar_test_*` keyspace, inserts bilingual-UTF-8 rows
(`চাল-rice` …), reads them back (count / value via `SELECT JSON`), then **drops the keyspace and proves zero
residue** (`system_schema.keyspaces`).

### A. Scripted test (the shared contract test)

```bash
# from utility/14_ScyllaDB/  (reads host/port from 01_native_single/.env)
bash test.sh 01_native_single

# or against ANY ScyllaDB (e.g. cross-host):
SCYLLA_HOST=<host> SCYLLA_CQL_PORT=9042 bash test.sh
```

Exits `0` and prints `RESULT: PASS — keyspace created/written/read/dropped, zero residue.` when every check
passes. The client auto-selects: host `cqlsh` if on PATH, else `cqlsh` inside a `scylladb/scylla` Docker
container (`--network host`).

### B. Manual test (raw write → read → clean-up)

```bash
# write → read round-trip on a throwaway keyspace, then DROP it (zero residue) — mirror of test.sh
HOST="$(hostname -I | awk '{print $1}')"
cqlsh "$HOST" 9042 -e "
CREATE KEYSPACE dokandar_smoke WITH replication = {'class':'SimpleStrategy','replication_factor':1};
USE dokandar_smoke;
CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t (id,name) VALUES (1,'চাল-rice');
SELECT name FROM t WHERE id=1;"                 # -> চাল-rice

# clean up + prove zero residue
cqlsh "$HOST" 9042 -e "DROP KEYSPACE dokandar_smoke;"
cqlsh "$HOST" 9042 -e "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name='dokandar_smoke';"  # -> (0 rows)
```

## Status / logs

```bash
sudo bash setup.sh status        # service + CQL reachability + nodetool ring + data-dir size
# manual equivalents:
systemctl is-active scylla-server && nodetool status
journalctl -u scylla-server -n 80 --no-pager
```

## Uninstall

### A. Scripted uninstall

Removes the package + repo files but **keeps the data** at `/data/scylla`:

```bash
sudo bash setup.sh uninstall     # package + repo removed; DATA PRESERVED at /data/scylla
sudo bash setup.sh purge         # also deletes /data/scylla + /etc/scylla (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + disable, purge the package + repo files (data on /data is NOT touched)
sudo systemctl stop scylla-server
sudo systemctl disable scylla-server
sudo apt-get purge -y scylla 'scylla-*'
sudo apt-get autoremove --purge -y
sudo rm -f /etc/apt/sources.list.d/scylla.list /etc/apt/keyrings/scylladb.gpg
sudo rm -f /var/lib/scylla              # this is the symlink, not the data

# full wipe — ALSO delete the data + config (irreversible)
sudo rm -rf /data/scylla /etc/scylla
```

## See also

- `../README.md` — the utility ScyllaDB overview + the shared `test.sh`.
- `../03_docker_single/` — the Docker single-node variant (no host packages needed).
- `../04_docker_cluster/` — the Docker HA 3-node ring (`replication_factor=3`).
- `../../../dependencies/03_Databases_datastores/10_ScyllaDB_2026.1/` — the deps-layer install script + the
  `cluster_mode/run_book.md` (RECORD-ONLY on the shared native fleet — documents the `--smp`/`--memory` caps
  and the full `scylla_setup` host tuning this utility skips).
