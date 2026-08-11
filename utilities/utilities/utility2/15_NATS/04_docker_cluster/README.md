# NATS JetStream 2.14 — Docker Compose, HA cluster (3-node mesh)

A high-availability NATS JetStream cluster via Docker Compose: **3 symmetric nodes** meshed by static
**routes** (`6222`), JetStream on every node. **R3 (replicas=3)** streams/KV are RAFT-replicated across all
three, so the cluster tolerates one node loss. There is **no primary** — JetStream elects a meta-group
leader (and per-stream leader) automatically via RAFT. Tested on Ubuntu 26.04 (live on AWS, local +
cross-host).

```text
   client :4222          client :4223          client :4224
        │                     │                     │
        ▼                     ▼                     ▼
   ┌──────────┐  routes  ┌──────────┐  routes  ┌──────────┐
   │  nats1   │◄────────►│  nats2   │◄────────►│  nats3   │
   │ mon :8222│  :6222   │ mon :8223│  :6222   │ mon :8224│
   └──────────┘◄─────────┴──────────┴─────────►└──────────┘
        symmetric — any node accepts pub/sub; R3 = RAFT-replicated across all 3
```

Any node accepts pub/sub. R3 streams/KV survive one node down (quorum 2/3). The route mesh `6222` carries
RAFT/replication and is firewalled to the cluster (SG-fenced); the token only protects client connections.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the token, brings up the 3 nodes, verifies the mesh, then runs the acceptance gate, prints a
connection summary); and **B. Manual** — raw `docker compose` + Ubuntu commands.

## How it works (and why the data survives `down -v`)

- Each node stores its JetStream store on a **host bind mount** at the container's `/data` path:
  `${DATA_ROOT}/nats_cluster/{n1,n2,n3}`. There is **no named volume**, so `docker compose down -v` keeps
  all three nodes' data and they re-form the mesh on `up`.
- All three are **symmetric** (`x-nats` anchor): each runs `-js -sd /data --cluster nats://0.0.0.0:6222
  --routes nats://nats1,2,3:6222`, identical token. The **mesh is fully automatic on `up`** — Docker DNS
  resolves `nats1/2/3` on the compose network and the routes form themselves. **There is no manual
  cluster-init step** (unlike a static-quorum native cluster).
- R3 buckets/streams are RAFT-replicated across the three nodes; a write on any node is readable on the
  others, and the cluster keeps serving with one node down (quorum 2/3).

## Prerequisites

Docker Engine + Compose plugin (see `../03_docker_single/README.md` for the install). The shared `test.sh`
uses the `nats` CLI; if it isn't on the host it falls back to the `natsio/nats-box` image automatically.

## Configure

```bash
cp .env.example .env        # set host ports if 4222–4224 / 8222–8224 are taken; image tag optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `NATS_IMAGE` (default `nats:2.14`),
`NATS_CLUSTER_NAME` (default `dokandar`), `NATS_AUTH_TOKEN`, the per-node client ports
`N_CLIENT1`/`N_CLIENT2`/`N_CLIENT3` (`4222`/`4223`/`4224`), the per-node monitor ports
`N_MON1`/`N_MON2`/`N_MON3` (`8222`/`8223`/`8224`), and `DATA_ROOT`. The route mesh `6222` is internal to
the compose network. **Leave `NATS_AUTH_TOKEN` empty to auto-generate a complex token** (identical on all
3 nodes) — `setup.sh up` fills it before `docker compose up`. **A direct `docker compose up` needs it set
non-empty in `.env`** — every node declares `--auth ${NATS_AUTH_TOKEN:?set in .env}` and **refuses to
start** with an empty token — so the manual path sets it explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                  # generates the token, brings up 3 nodes, runs the acceptance gate
bash setup.sh up --token 'mytok'  # or set the token explicitly
bash setup.sh up --gen-token      # rotate to a fresh generated token (re-creates the mesh)
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3 + acceptance): resolves the token (saved to
`.env`), creates the three per-node bind-mount data dirs (`chown 1000:1000`), `docker compose up -d` (the
route mesh forms itself), waits for each node's `/healthz`, verifies the **mesh** (each node's `/routez`
shows 2 routes), then runs the **acceptance gate** (below). It ends with a **connection summary** (all
three client URLs, the shared auth token, the three monitoring URLs, and the per-node data paths); the
token is shown once and saved to `.env`. A no-flag re-run reuses it.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET THE TOKEN (every node refuses to start with an empty --auth token)
cp .env.example .env
sed -i "s/^NATS_AUTH_TOKEN=.*/NATS_AUTH_TOKEN=ChangeMe_StrongToken/" .env

# 2. create the three per-node host bind-mount data dirs (image runs as uid 1000)
sudo mkdir -p /data/nats_cluster/n1 /data/nats_cluster/n2 /data/nats_cluster/n3
sudo chown -R 1000:1000 /data/nats_cluster

# 3. bring up the whole cluster (route mesh forms automatically — no manual init step)
docker compose up -d

# 4. wait until all three /healthz answer 200
for p in 8222 8223 8224; do curl -fsS -o /dev/null -w "mon $p -> %{http_code}\n" "http://127.0.0.1:$p/healthz"; done

# 5. verify the route mesh formed (each node should see 2 routes)
for p in 8222 8223 8224; do
  echo -n "mon $p routes="; curl -s "http://127.0.0.1:$p/routez" | grep -oE '"num_routes": *[0-9]+' | grep -oE '[0-9]+' | head -1
done
```

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh accept        # re-run the acceptance gate (also run automatically by `up`)
```

Runs the run book's 3 criteria: (1) the **route mesh** is formed (each node's `/routez` shows 2 routes);
(2) a **JetStream R3** KV bucket — only creatable on a real 3-node cluster — written via **node1** is read
back via **node2 AND node3** (RAFT replication), UTF-8 intact; (3) **failover** — stop **nats3**, the KV is
still writable/readable via node1/node2 (R3 quorum 2/3), then nats3 rejoins the mesh. Cleans up after
itself.

### B. Manual acceptance (write on node1 → read on node2 + node3 → assert R3 + failover)

```bash
TOKEN=ChangeMe_StrongToken
# helper: run the nats CLI against the node on a given client port
na(){ local p="$1"; shift; docker run --rm --network host natsio/nats-box:latest nats -s "nats://${TOKEN}@127.0.0.1:${p}" "$@"; }

# (1) every node sees 2 routes (the mesh is formed)
for p in 8222 8223 8224; do echo -n "mon $p routes="; curl -s "http://127.0.0.1:$p/routez" | grep -oE '"num_routes": *[0-9]+' | grep -oE '[0-9]+' | head -1; done

# (2) create an R3 KV bucket (only possible on a real 3-node cluster), write on node1...
na 4222 kv add HACHK --replicas=3 --history=1
na 4222 kv put HACHK rice 'চাল-rice'
# ...read it back on node2 AND node3 (proves RAFT replication, UTF-8 intact)
na 4223 kv get HACHK rice --raw          # -> চাল-rice
na 4224 kv get HACHK rice --raw          # -> চাল-rice

# (3) failover: stop node3, the R3 KV is still writable/readable (quorum 2/3)
docker compose stop nats3
na 4222 kv put HACHK rice 'survived'
na 4223 kv get HACHK rice --raw          # -> survived
docker compose start nats3               # nats3 rejoins the mesh

# clean up
na 4222 kv rm HACHK -f
```

## Test (the shared contract test, via node 1)

### A. Scripted test

```bash
# from utility/15_NATS/
bash test.sh 04_docker_cluster

# or drive it explicitly (cross-host; use your actual token)
NATS_HOST=<host> NATS_CLIENT_PORT=4222 NATS_AUTH_TOKEN='<your-token>' bash test.sh
```

Reads this `.env` (`NATS_CLIENT_PORT` = node 1), creates a throwaway KV bucket — **R3 on the cluster**, so
it actually exercises RAFT replication across all three nodes — puts/gets the UTF-8 value, then deletes the
key + bucket and proves zero residue.

### B. Manual test (raw write → read → clean-up via node 1)

```bash
TOKEN=ChangeMe_StrongToken
URL="nats://${TOKEN}@127.0.0.1:4222"
NB(){ docker run --rm --network host natsio/nats-box:latest nats -s "$URL" "$@"; }

NB account info | grep -iE 'JetStream|Streams'    # connectivity + JetStream responding
NB kv add DOKTEST --replicas=3 --history=1         # R3 bucket — RAFT-replicated across the 3 nodes
NB kv put DOKTEST rice 'চাল-rice'
NB kv get DOKTEST rice --raw                        # -> চাল-rice
NB kv del DOKTEST rice -f
NB kv rm  DOKTEST -f
NB kv ls | grep -q DOKTEST && echo 'RESIDUE!' || echo 'clean — zero residue'
```

## Connection model

- **Any node is writable** — clients can connect to `127.0.0.1:4222` (n1), `:4223` (n2), or `:4224` (n3);
  all are symmetric. R3 streams/KV are RAFT-replicated across all three.
- A node-down event keeps R3 streams serving via the remaining two (quorum 2/3); JetStream re-elects the
  per-stream leader automatically.

## Status / logs

```bash
bash setup.sh status        # compose ps + per-node /healthz + route counts + host data size
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/nats_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the three per-node host data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/nats_cluster
```

## Notes

- **No browser UI** — `:8222`/`:8223`/`:8224` serve JSON monitoring (`/jsz` shows the JetStream meta
  cluster, `/routez` the route mesh); use the `nats` CLI.
- Route mesh `6222` carries RAFT/replication and is firewalled to the cluster (SG-fenced); the token only
  protects client connections (`4222`/`4223`/`4224`).
- Production = TLS on client + routes, dedicated hosts/AZs per node, and bounded
  `max_memory_store` / `max_file_store` (see the native runbook).

## See also

- `../README.md` — using `test.sh` across all variants.
- `../03_docker_single/` — the Docker single-node variant.
- `../../../dependencies/04_Messaging_streaming/03_NATS_JetStream_2.14/cluster_mode/run_book.md` — the
  native (no-Docker) HA run book this mirrors.
