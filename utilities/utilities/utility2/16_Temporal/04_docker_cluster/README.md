# Temporal — Docker Compose HA cluster (PostgreSQL + 3 servers + UI)

One **PostgreSQL** durable store + **3 temporal-server nodes** (all 4 roles each:
frontend/history/matching/worker) sharing it + the companion **temporalio/ui** Web UI. Temporal's services
are **stateless** — HA comes from the shared DB and the `cluster_membership` rings, so the cluster survives
one node loss. Per-node + PG data are **host bind mounts** so they **survive `docker compose down -v`**.
Tested on Ubuntu 26.04 (verified live on AWS, local + cross-host).

```text
                writes / reads (any frontend serves the whole cluster)
        ┌──────────────┬──────────────────────┬──────────────────────┐
        ▼              ▼                       ▼
 ┌────────────┐   ┌────────────┐        ┌────────────┐
 │ temporal1  │   │ temporal2  │        │ temporal3  │
 │ :7233 gRPC │   │ :7234 gRPC │        │ :7235 gRPC │      ──► companion UI :8233
 │ (schema    │   │ (skip      │        │ (skip      │
 │  setup)    │   │  schema)   │        │  schema)   │
 └─────┬──────┘   └─────┬──────┘        └─────┬──────┘
       └────────────────┴──────── shared ─────┴───────────┐
                                                          ▼
                                            ┌──────────────────────────┐
                                            │ PostgreSQL (durable store)│
                                            │ temporal + temporal_visib.│
                                            └──────────────────────────┘
```

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the PG password, brings up PG + node1 for schema setup, then nodes 2/3 + UI, runs the acceptance
gate, prints a credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands.

## How it works (and why the data survives `down -v`)

- The **PostgreSQL** store lives on a **host bind mount** at `${DATA_ROOT}/temporal_cluster/pg`
  (→ container `/var/lib/postgresql/data`). There is **no named volume**, so `docker compose down -v` keeps
  the store and the next `up` re-attaches it.
- **node1** (`temporal1`) runs schema setup on first up (`SKIP_SCHEMA_SETUP=false SKIP_DB_CREATE=false` on
  the `temporalio/auto-setup` image) — it creates the `temporal` + `temporal_visibility` databases/schemas.
  **nodes 2/3** skip schema setup (`SKIP_*=true`) since the schema already exists. This is why `setup.sh`
  brings up **PostgreSQL + node1 first**, waits for node1's frontend, **then** starts nodes 2/3 — to avoid
  three concurrent schema setups racing on one DB.
- All three servers are **stateless** and share the one PostgreSQL store; any frontend serves the whole
  cluster. The schema-setup ordering is the only init step — once the schema exists, every `up` is idempotent.

## Prerequisites

Docker Engine + Compose plugin (see `../03_docker_single/README.md` for the install). No host `temporal`
CLI is needed — `setup.sh accept`, `test.sh`, and the manual test below run the CLI **inside** a throwaway
`temporalio/admin-tools` container (`docker run --rm --network host`).

## Configure

```bash
cp .env.example .env        # set host ports if 7233–7235/8233 are taken; image tags / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `TEMPORAL_IMAGE`
(`temporalio/auto-setup`), `TEMPORAL_UI_IMAGE`, `POSTGRES_IMAGE` (`postgres:16`), `PG_PASSWORD` (the
PostgreSQL password for the `temporal` user — **the durable store's only secret**), and the host gRPC ports
`T_GRPC1`/`T_GRPC2`/`T_GRPC3` (node1/2/3) + `T_UI` (Web UI). **Leave `PG_PASSWORD` empty to auto-generate a
complex (24-char) password** — `setup.sh up` fills it before `docker compose up` and writes it back to
`.env`. **A direct `docker compose up` needs `PG_PASSWORD` set non-empty in `.env`** — the compose file
declares `${PG_PASSWORD:?set in .env}`, so it refuses to start with an empty password — so the manual path
sets one explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up                              # auto-generates the PG password, then full bring-up + acceptance
bash setup.sh up --password 'MyOwnSecret'     # or set the PG password explicitly
bash setup.sh up --gen-password               # rotate to a fresh generated PG password
```

`setup.sh up` prints **numbered step output** (1/4 … 4/4): resolves the PG password → brings up
**PostgreSQL + node1** and waits for node1's frontend (**schema setup runs first** — that's why node1
starts alone) → brings up **nodes 2/3 + the UI** and waits for their frontends → confirms 3 frontends
reachable → runs the **acceptance gate** (below). It ends with a **credentials summary** (the three frontend
endpoints, the browser-UI URL, and the PostgreSQL user/password, shown once and saved to `.env`).

### B. Manual install (raw docker compose)

The cluster needs an **explicit two-phase bring-up**: PostgreSQL + node1 first (node1 initialises the
schema), then nodes 2/3 + UI. Don't `docker compose up -d` everything at once on a fresh store, or 2/3 may
race node1's schema setup.

```bash
# 1. create the env file and SET THE PG PASSWORD (compose declares ${PG_PASSWORD:?...}, refuses empty)
cp .env.example .env
sed -i "s/^PG_PASSWORD=.*/PG_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. create the PostgreSQL host bind-mount data dir (postgres runs as uid 999 in the image)
sudo mkdir -p /data/temporal_cluster/pg
sudo chown -R 999:999 /data/temporal_cluster/pg

# 3. bring up PostgreSQL + node1 FIRST — node1 runs schema setup (creates temporal + temporal_visibility)
docker compose up -d postgres temporal1

# 4. wait for node1's frontend (schema setup runs before it answers)
for _ in $(seq 1 60); do docker run --rm --network host temporalio/admin-tools:latest \
  temporal --address 127.0.0.1:7233 operator namespace list >/dev/null 2>&1 && break; sleep 3; done

# 5. now bring up nodes 2/3 (they skip schema setup) + the Web UI
docker compose up -d

# 6. wait for the node2/node3 frontends, then verify all three answer
for p in 7234 7235; do for _ in $(seq 1 40); do docker run --rm --network host temporalio/admin-tools:latest \
  temporal --address 127.0.0.1:$p operator namespace list >/dev/null 2>&1 && break; sleep 3; done; done
docker compose ps
for p in 7233 7234 7235; do docker run --rm --network host temporalio/admin-tools:latest \
  temporal --address 127.0.0.1:$p operator namespace list >/dev/null 2>&1 && echo "frontend :$p OK" || echo "frontend :$p DOWN"; done
```

- **Browser UI:** `http://<host>:8233` (companion `temporalio/ui`, pointed at node1; container port `8080`
  → host `T_UI` 8233). No login (dev posture; keep it SG-fenced).

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh accept
```

Runs the gate's 3 criteria: (1) all **3 frontends** answer; (2) a **namespace created via node1** is
visible on **node2 AND node3** (shared PostgreSQL store; each frontend caches namespaces and refreshes on
an interval, so the cross-node read is retried), with its **UTF-8 description (`চাল-rice`) intact**; (3)
**failover** — stop **node3**, the cluster still serves namespace ops via node1/node2, then node3 rejoins.
Cleans up the test namespace after itself.

### B. Manual acceptance (write on node1 → read on node2/node3 → failover)

```bash
TC(){ p="$1"; shift; docker run --rm --network host temporalio/admin-tools:latest temporal --address 127.0.0.1:$p "$@"; }
NS="hachk_$(date +%s)"

# (1) all 3 frontends reachable
for p in 7233 7234 7235; do TC $p operator namespace list >/dev/null 2>&1 && echo "frontend :$p OK" || echo "frontend :$p DOWN"; done

# (2) create the namespace via NODE1, then read it back on NODE2 + NODE3 (shared store — retry the cache refresh)
TC 7233 operator namespace create "$NS" --retention 24h --description 'চাল-rice'
for p in 7234 7235; do for _ in $(seq 1 20); do TC $p operator namespace describe "$NS" >/dev/null 2>&1 && { echo "node :$p sees it"; break; }; sleep 2; done; done
TC 7234 operator namespace describe "$NS" | grep -iE 'Description'      # -> চাল-rice (UTF-8 intact on node2)

# (3) failover: stop node3, ops still work via node1/node2, then bring node3 back
docker compose stop temporal3; sleep 5
TC 7234 operator namespace describe "$NS" >/dev/null 2>&1 && echo "still serving with node3 down"
docker compose start temporal3

# clean up the test namespace
TC 7233 operator namespace delete "$NS" --yes
```

## Test (the shared contract test, against node 1)

The shared contract test creates a **throwaway** `dokandar_test_*` namespace via node1, exercises the
frontend + persistence (create / describe / list), then **deletes it and proves zero residue**.

### A. Scripted test

```bash
# from utility/16_Temporal/  (reads this .env — T_GRPC1 is node 1)
bash test.sh 04_docker_cluster

# or point it at a host explicitly (cross-host)
TEMPORAL_HOST=<host> TEMPORAL_GRPC_PORT=7233 bash test.sh
```

### B. Manual test (raw write → read → clean-up on node 1)

```bash
TC(){ docker run --rm --network host temporalio/admin-tools:latest temporal --address 127.0.0.1:7233 "$@"; }
NS="dokandar_smoke_$$"
TC operator namespace create "$NS" --retention 24h --description 'চাল-rice'   # write
TC operator namespace describe "$NS" | grep -iE 'Description'           # read -> চাল-rice
TC operator namespace delete "$NS" --yes                                # delete
for _ in $(seq 1 15); do TC operator namespace describe "$NS" >/dev/null 2>&1 || { echo gone; break; }; sleep 2; done
```

## Connection model

- **Any frontend serves the whole cluster** — the three servers are stateless and share one PostgreSQL
  store. Point clients/SDKs at any of `127.0.0.1:7233` (node1) / `:7234` (node2) / `:7235` (node3);
  spreading load across them is the HA play (a downed node just removes one frontend).
- The companion UI is pointed at node1 (`TEMPORAL_ADDRESS=temporal1:7233`).

## Failover (manual)

Stop any single node; the cluster keeps serving via the other two (verified by the acceptance gate):

```bash
docker compose stop temporal3            # drop a node
# ... cluster still serves via node1/node2 ...
docker compose start temporal3           # it rejoins the cluster_membership ring
```

## Status / logs

```bash
bash setup.sh status        # compose ps + each frontend (:7233/:7234/:7235) up-check + host data size
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/temporal_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — the bind-mounted PostgreSQL store is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/temporal_cluster
```

## Notes

- **Image version:** `temporalio/auto-setup` publishes no `1.31.x` point tags, so this uses `:latest`
  (server 1.29.x at time of writing). The dev-server variants (`01`/`03`) run the CLI's embedded server
  (1.31.x). Pin `TEMPORAL_IMAGE` to a specific `auto-setup` tag matching §8's 1.31 pin once one is published.
- **Password rotation:** `--gen-password` rotates the PG password (`setup.sh up --gen-password`). It is the
  PostgreSQL store's only secret; the Temporal servers read it from `POSTGRES_PWD` at start.
- Production HA would add TLS, dedicated hosts/AZs per node, an HA PostgreSQL (e.g. the `01_PostgreSQL`
  cluster), and Elasticsearch for advanced visibility (see the native runbook).

## See also

- `../README.md` — using `test.sh` across all variants.
- `../03_docker_single/` — the single-node dev server (SQLite, no PostgreSQL).
- `../../../dependencies/05_Workflow_engine/01_Temporal_1.31/cluster_mode/run_book.md` — the native
  (no-Docker) multi-role HA run book (frontend/history/matching/worker + `temporal-sql-tool` schema steps).
