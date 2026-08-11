# ScyllaDB 2026.1 — Docker Compose, HA cluster (3-node ring)

A high-availability ScyllaDB cluster via Docker Compose: **three `scylladb/scylla:2026.1` nodes forming one
ring** (`cluster_name=dokandar`). **scylla1 is the seed**; scylla2/scylla3 join it. With a keyspace at
**`replication_factor=3`** every node holds a full copy, so the ring survives one node loss (reads/writes at
quorum 2/3). There is **no single primary** — every node coordinates. Per-node data is on **host bind
mounts** so it **survives `docker compose down -v`**. ScyllaDB ships with the **authenticator off** and has
**no browser UI** — interact via **`cqlsh`** / **`nodetool`**. Tested on Ubuntu 26.04, local + cross-host.

```text
                     one ring  (cluster_name=dokandar, RF=3)
   ┌──────────────┐        ┌──────────────┐        ┌──────────────┐
   │   scylla1    │◄──────►│   scylla2    │◄──────►│   scylla3    │
   │  (seed)      │ gossip │              │ gossip │              │
   │ host :9042   │        │ host :9043   │        │ host :9044   │
   └──────────────┘        └──────────────┘        └──────────────┘
     every node is read+write; RF=3 → any node serves any key; quorum 2/3 survives one loss
```

Nodes **must bootstrap one at a time** — `depends_on: service_healthy` serialises the join (scylla2 waits
for scylla1 healthy, scylla3 for scylla2). **The ring forms automatically on `up`** (seed + gossip) — there
is no manual cluster-init step.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh` (raises
the host AIO limit, brings the ring up serially, waits for 3 `UN` nodes, runs the acceptance gate, prints a
connection summary); and **B. Manual** — raw `docker compose` + Ubuntu commands.

## How it works (and why the data survives `down -v`)

- Each node stores its data on a **host bind mount** at `${DATA_ROOT}/scylla_cluster/n{1,2,3}` →
  `/var/lib/scylla`. There is **no named volume**, so `docker compose down -v` keeps all three nodes' data
  and the ring re-forms on `up`.
- All three run `--seeds=scylla1 --developer-mode 1 --smp 1 --memory 1G --overprovisioned 1`; the
  `nodetool status` healthcheck gates the serial join.
- **Host AIO limit.** Three Scylla nodes share the host kernel's AIO contexts; the default `fs.aio-max-nr`
  is exhausted by the first two nodes, so the third fails Seastar init ("does not satisfy minimum AIO
  requirements"). `setup.sh up` raises it (`sudo sysctl -w fs.aio-max-nr=1048576`) — the manual path does
  the same. (`scylla_setup` would set this natively; in dev-mode/Docker you still need the host limit for
  >1 node.)

## Prerequisites — install Docker (one time)

Docker isn't in the Ubuntu base repo. See `../03_docker_single/README.md` for the Docker Engine + Compose
plugin install. You do **not** need a host CQL client — the acceptance gate and tests run `cqlsh` inside a
throwaway `scylladb/scylla` container with `--network host`.

## Configure

```bash
cp .env.example .env        # set the three host CQL ports if 9042-9044 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `SCYLLA_IMAGE` (default
`scylladb/scylla:2026.1`), `SCYLLA_CLUSTER_NAME` (default `dokandar`), the host CQL ports `SCY_CQL1` /
`SCY_CQL2` / `SCY_CQL3` (default `9042`/`9043`/`9044` — n1/n2/n3, used for the read-there proof),
`DATA_ROOT` (default `/data`). **There is no password to set** — ScyllaDB's authenticator is off by
default, so the ring starts with an empty `.env` (no required secret). If `9042-9044` are taken on this
host, change all three.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                 # serial bootstrap (scylla1 -> scylla2 -> scylla3); slow, then acceptance
```

`setup.sh up` (3 steps + acceptance): creates the three per-node bind dirs (chowned to uid `999`) and raises
`fs.aio-max-nr` → `docker compose up -d` (serial join) and polls for **3 `UN` nodes** (`nodetool status`) →
prints the ring + a **connection summary** (the three CQL endpoints, the `Auth: none` note, the test
command, the host data dirs) → runs the **acceptance gate** (see below). The first replica takes ~30-60 s
longer to go healthy because the join is serial.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file (no secret to set — ScyllaDB has no auth by default)
cp .env.example .env

# 2. create the three per-node bind dirs and chown them to the image's scylla uid (999)
sudo mkdir -p /data/scylla_cluster/n1 /data/scylla_cluster/n2 /data/scylla_cluster/n3
sudo chown -R 999:999 /data/scylla_cluster

# 3. raise the host AIO limit (the 3rd node fails Seastar init otherwise)
sudo sysctl -w fs.aio-max-nr=1048576

# 4. bring up the whole ring (seed first; scylla2/scylla3 auto-join via gossip — no manual init)
docker compose up -d

# 5. BLOCK until all three report UN (Up/Normal). The serial bootstrap is slow (multi-minute); without this
#    wait the acceptance below reads node2/node3 before they exist and fails. Mirror of setup.sh's poll.
until [ "$(docker exec dokandar_scylla_c1 nodetool status 2>/dev/null | grep -c '^UN')" = 3 ]; do sleep 5; done
docker exec dokandar_scylla_c1 nodetool status | grep -c '^UN'        # -> 3
docker exec dokandar_scylla_c1 nodetool status                        # full ring view
```

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh accept             # re-run the acceptance gate (also run automatically by `up`)
```

Runs the 3 criteria: (1) `nodetool status` shows **3 `UN`** nodes; (2) a keyspace at `replication_factor=3`
written via **node1** is read back via **node2 and node3** (replication, UTF-8 intact); (3) **failover** —
stop **scylla3**, a write to node1 still succeeds and node2 serves the read (RF=3, quorum 2/3), then scylla3
rejoins the ring. Cleans up the keyspace after itself.

### B. Manual acceptance (write on node1 → read on node2/node3 → failover)

```bash
# helper: run CQL against the node on host port $1 (throwaway scylladb/scylla container, --network host)
cql(){ docker run --rm --network host --entrypoint cqlsh scylladb/scylla:2026.1 127.0.0.1 "$1" --request-timeout=25 -e "$2"; }

# (1) ring has 3 UN nodes
docker exec dokandar_scylla_c1 nodetool status | grep -c '^UN'        # -> 3

# (2) RF=3 keyspace: WRITE via node1 (:9042) ...
cql 9042 "CREATE KEYSPACE ha_check WITH replication = {'class':'SimpleStrategy','replication_factor':3};
USE ha_check; CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t (id,name) VALUES (1,'চাল-rice'); INSERT INTO t (id,name) VALUES (2,'ডিম-egg');"
sleep 2
# ... READ on node2 (:9043) and node3 (:9044) — replication carried the rows there
cql 9043 "SELECT JSON count(*) FROM ha_check.t;"                      # -> {"count": 2}
cql 9044 "SELECT JSON count(*) FROM ha_check.t;"                      # -> {"count": 2}
cql 9043 "SELECT JSON name FROM ha_check.t WHERE id=1;"              # -> {"name": "চাল-rice"}

# (3) failover: stop scylla3, write+read still work at quorum 2/3
docker compose stop scylla3; sleep 6
cql 9042 "INSERT INTO ha_check.t (id,name) VALUES (3,'মাছ-fish');"
cql 9043 "SELECT JSON count(*) FROM ha_check.t;"                      # -> {"count": 3} (served with scylla3 down)
docker compose start scylla3                                         # scylla3 re-joins the ring

# clean up
cql 9042 "DROP KEYSPACE IF EXISTS ha_check;"
```

## Test

The shared contract test creates a throwaway `dokandar_test_*` keyspace via node1, inserts bilingual-UTF-8
rows, reads them back, then drops the keyspace and proves zero residue.

### A. Scripted test

```bash
# from utility/14_ScyllaDB/
bash test.sh 04_docker_cluster                       # contract via node 1 (reads SCY_CQL1 from .env)

# or against ANY ScyllaDB (e.g. cross-host):
SCYLLA_HOST=<host> SCYLLA_CQL_PORT=9042 bash test.sh
```

### B. Manual test (raw write → read → clean-up via node1)

```bash
# through node1 (:9042), via a throwaway scylladb/scylla container — mirror of test.sh
cql(){ docker run --rm --network host --entrypoint cqlsh scylladb/scylla:2026.1 127.0.0.1 "$1" --request-timeout=25 -e "$2"; }

cql 9042 "
CREATE KEYSPACE dokandar_smoke WITH replication = {'class':'SimpleStrategy','replication_factor':3};
USE dokandar_smoke; CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t (id,name) VALUES (1,'চাল-rice');
SELECT name FROM t WHERE id=1;"                       # -> চাল-rice

# clean up + prove zero residue
cql 9042 "DROP KEYSPACE dokandar_smoke;"
cql 9042 "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name='dokandar_smoke';"  # -> (0 rows)
```

## Connection model

- **Any node is read+write** (`127.0.0.1:9042` / `:9043` / `:9044`); with `replication_factor=3` every node
  holds every key, so any node can coordinate any query. Use RF=3 for HA.
- A token-aware driver connecting to one published port sees the other nodes' internal bridge IPs; for
  off-box token-aware clients, front the ring with an LB or expose routable addresses. `cqlsh` (coordinator
  path) works fine against any single published port.

## Status / logs

```bash
bash setup.sh status        # compose ps + UN-node count + host data size
bash setup.sh logs
# manual equivalents:
docker compose ps
docker exec dokandar_scylla_c1 nodetool status
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/scylla_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mounts survive -v

# full wipe — ALSO delete the three host data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/scylla_cluster
```

## Notes

- **No browser UI** — ScyllaDB is a CQL database; interact via `cqlsh` / `nodetool`.
- Developer mode + capped `--smp 1`/`--memory 1G` make 3 nodes fit one box. Production = `--developer-mode 0`
  with the full `scylla_setup` host tuning, dedicated hosts/AZs per node, and `--smp`/`--memory` sized to the
  hardware (see the deps-layer native runbook).

## See also

- `../README.md` — the utility ScyllaDB overview + how `test.sh` works across all variants.
- `../03_docker_single/` — the Docker single-node variant.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../../../dependencies/03_Databases_datastores/10_ScyllaDB_2026.1/cluster_mode/run_book.md` — the native
  (no-Docker) HA run book (RECORD-ONLY on the shared native fleet) this Docker ring realises as the tested
  HA path.
