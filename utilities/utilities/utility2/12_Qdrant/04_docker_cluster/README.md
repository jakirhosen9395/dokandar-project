# Qdrant 1.18 — Docker Compose, HA cluster (3-peer Raft)

Three `qdrant/qdrant:v1.18.2` containers forming **one Raft consensus group**: **q1 bootstraps** the
cluster (`--uri http://q1:6335`), **q2 and q3 join** it (`--bootstrap http://q1:6335`). Collection metadata
(which shard/replica lives where) is replicated by consensus to every peer; each shard's vector data is
replicated to `replication_factor` peers. There is **no single primary** — every peer accepts reads and
writes, and the cluster survives one node loss. Per-node storage is a **host bind mount** so it **survives
`docker compose down -v`**. Tested on Ubuntu 26.04, live on AWS (local + cross-host).

```text
                      one Raft consensus group  (p2p :6335, internal)
        ┌───────────────────────────┬───────────────────────────┐
        ▼                           ▼                           ▼
 ┌──────────────┐           ┌──────────────┐           ┌──────────────┐
 │      q1      │           │      q2      │           │      q3      │
 │ bootstrap    │  ◄─Raft─► │ join q1      │  ◄─Raft─► │ join q1      │
 │ REST :6333   │           │ REST :6343   │           │ REST :6353   │
 │ gRPC :6334   │           │              │           │              │
 └──────────────┘           └──────────────┘           └──────────────┘
   every peer accepts reads + writes; shards replicated to replication_factor peers
```

Replication factor `2` over `shard_number 3` means each shard lives on 2 peers, so the cluster tolerates
**one node down**. Cluster bring-up is **fully automatic** from the compose `command` flags — there is **no
manual cluster-init step**.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the API key, brings up the 3 peers, waits for consensus, runs the acceptance gate, prints a
connection summary); and **B. Manual** — raw `docker compose` + Ubuntu commands.

## How it works (and why the data survives `down -v`)

- Each peer stores its data on a **host bind mount** at the image's `/qdrant/storage` path:
  `${DATA_ROOT}/qdrant_cluster/n{1,2,3}`. There is **no named volume**, so `docker compose down -v` keeps
  all three peers' data + Raft state, and they re-attach on the next `up`.
- **q1** boots with `--uri http://q1:6335` (it bootstraps the consensus). **q2 / q3** boot with
  `--bootstrap http://q1:6335 --uri http://q2:6335` (resp. `q3`) and **join** q1's group over the p2p port.
  `QDRANT__CLUSTER__ENABLED=true` and the **same** `QDRANT__SERVICE__API_KEY` are set on all three.
- Collections created with `shard_number` + `replication_factor` spread each shard across peers; metadata
  replicates to every peer by Raft. **Replication is fully automatic on `up` — no `docker compose exec`
  init command is run.**

## Prerequisites — install Docker (one time)

Docker Engine + the Compose plugin (see `../03_docker_single/README.md` for the full install). The shared
`test.sh` and the cluster acceptance need only `curl` (already present, or they fall back to a
`curlimages/curl` container) — no extra client package.

## Configure

```bash
cp .env.example .env        # set host ports if 6333/6343/6353 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `QDRANT_IMAGE`, `QDRANT_API_KEY`, the
host REST ports `Q_HTTP1` (q1) / `Q_HTTP2` (q2) / `Q_HTTP3` (q3) + gRPC `Q_GRPC1` (q1), the collection HA
knobs `QDRANT_SHARD_NUMBER` (3) / `QDRANT_REPLICATION_FACTOR` (2), and `DATA_ROOT`. **Leave
`QDRANT_API_KEY` empty to auto-generate a complex (24-char) key** — `setup.sh up` fills it before
`docker compose up`. **A direct `docker compose up` needs a non-empty `QDRANT_API_KEY` in `.env`** — the
compose file declares it as `${QDRANT_API_KEY:?set in .env}` and **refuses to start** with an empty key,
and the **same single key is shared by all 3 peers** — so the manual path sets it explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                 # generates the key, brings up 3 peers, runs the acceptance gate
bash setup.sh up --key 'mykey'   # or set the shared API key explicitly
bash setup.sh up --gen-key       # rotate to a fresh generated key
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3) plus the acceptance gate: resolve the key + per-node
data dirs → `docker compose up -d` (q1 bootstraps, q2/q3 join via Raft) → poll each peer's `/readyz` →
verify **3-peer consensus on q1** → run **acceptance** (below). The API key is identical on all peers. It
ends with a **connection summary** (all 3 REST endpoints + q1 gRPC, the API key, the `/dashboard` URL, the
shard/replication factors); the key is shown once and saved to `.env`. A no-flag re-run reuses it.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET THE SHARED API KEY (compose refuses to start empty; same key on all peers)
cp .env.example .env
sed -i "s/^QDRANT_API_KEY=.*/QDRANT_API_KEY=ChangeMe_StrongApiKey/" .env

# 2. create the three per-node host bind-mount data dirs
sudo mkdir -p /data/qdrant_cluster/n1 /data/qdrant_cluster/n2 /data/qdrant_cluster/n3

# 3. bring up the whole cluster (stock image — NO --build; q1 bootstraps, q2/q3 auto-join via the
#    compose command flags — there is NO manual cluster-init exec step)
docker compose up -d

# 4. wait until all three publish /readyz (q2/q3 join via Raft and can take longer on a fresh up),
#    then verify 3-peer Raft consensus on q1 (should print 3)
for p in 6333 6343 6353; do
  for _ in $(seq 1 40); do curl -fsS "http://127.0.0.1:${p}/readyz" >/dev/null 2>&1 && break; sleep 2; done
  echo "  :${p} ready"
done
# give Raft a moment to settle the 3-peer consensus, then count distinct peer URIs on q1
for _ in $(seq 1 30); do
  [ "$(curl -fsS -H 'api-key: ChangeMe_StrongApiKey' http://127.0.0.1:6333/cluster \
    | grep -oE '"uri":"[^"]*"' | sort -u | wc -l)" = 3 ] && break; sleep 2
done
curl -fsS -H 'api-key: ChangeMe_StrongApiKey' http://127.0.0.1:6333/cluster \
  | grep -oE '"uri":"[^"]*"' | sort -u | wc -l                                     # -> 3
```

**Browser UI:** open `http://<host>:6333/dashboard` on **any** peer (the same collections appear
everywhere) and paste the API key into its **Settings** panel.

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh accept             # re-run the acceptance gate (also run automatically by `up`)
```

Runs 3 criteria: (1) every peer's `GET /cluster` reports **3 peers**, status enabled; (2) a collection with
**`shard_number=3, replication_factor=2`** is created on q1, its metadata replicates to q2 + q3, and the 3
points written via **q1** are read back via **q2 and q3** (count=3, UTF-8 payload intact); (3) **failover** —
with **q3 stopped**, a search via **q1** still returns the point (`replication_factor=2` tolerates one node
down), then q3 rejoins the consensus. Cleans up after itself.

### B. Manual acceptance (write on q1 → read on q2 + q3 → node-down failover)

```bash
KEY='ChangeMe_StrongApiKey'; C="ha_check"

# (1) every peer agrees on a 3-node consensus (each should print 3)
for p in 6333 6343 6353; do
  echo -n ":${p} peers="; curl -fsS -H "api-key: ${KEY}" "http://127.0.0.1:${p}/cluster" \
    | grep -oE '"uri":"[^"]*"' | sort -u | wc -l; done

# (2) sharded + replicated collection on q1; write via q1, read via q2 AND q3
curl -fsS -X PUT "http://127.0.0.1:6333/collections/${C}" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' \
  -d '{"vectors":{"size":4,"distance":"Dot"},"shard_number":3,"replication_factor":2}'
sleep 3   # let the collection metadata replicate to q2 + q3 via Raft before writing points
curl -fsS -X PUT "http://127.0.0.1:6333/collections/${C}/points?wait=true" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"points":[
    {"id":1,"vector":[0.9,0.1,0.0,0.0],"payload":{"name":"চাল-rice"}},
    {"id":2,"vector":[0.1,0.9,0.0,0.0],"payload":{"name":"ডিম-egg"}},
    {"id":3,"vector":[0.0,0.0,0.9,0.1],"payload":{"name":"মাছ-fish"}}]}'
sleep 2
curl -fsS -X POST "http://127.0.0.1:6343/collections/${C}/points/count" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"exact":true}'                         # q2 -> "count":3
curl -fsS -X POST "http://127.0.0.1:6353/collections/${C}/points/count" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"exact":true}'                         # q3 -> "count":3
curl -fsS "http://127.0.0.1:6343/collections/${C}/points/1" -H "api-key: ${KEY}"  # q2 -> "name":"চাল-rice"

# (3) failover: stop q3; a search via q1 still returns the point (replication_factor=2 tolerates 1 down)
docker compose stop q3 && sleep 4
curl -fsS -X POST "http://127.0.0.1:6333/collections/${C}/points/search" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"vector":[0.9,0.1,0.0,0.0],"limit":1}' # -> top "id":1
docker compose start q3
# poll until q3 has rejoined the consensus (rejoin can take longer than a fixed sleep)
for _ in $(seq 1 20); do
  [ "$(curl -fsS -H "api-key: ${KEY}" http://127.0.0.1:6333/cluster \
    | grep -oE '"uri":"[^"]*"' | sort -u | wc -l)" = 3 ] && break; sleep 2
done
curl -fsS -H "api-key: ${KEY}" http://127.0.0.1:6333/cluster \
  | grep -oE '"uri":"[^"]*"' | sort -u | wc -l                                     # -> 3 (q3 rejoined)

# clean up
curl -fsS -X DELETE "http://127.0.0.1:6333/collections/${C}" -H "api-key: ${KEY}"
```

## Test (the shared contract test, via q1)

### A. Scripted test

```bash
# from utility/12_Qdrant/  — runs the contract against q1
bash ../test.sh 04_docker_cluster

# or drive it explicitly (use your actual key)
QDRANT_HOST=<host> QDRANT_HTTP_PORT=6333 QDRANT_API_KEY='<your-key>' bash ../test.sh
```

Creates a **throwaway** collection on q1, upserts bilingual-UTF-8 points, reads them back (count / payload /
ANN search), then deletes the collection and **proves zero residue**.

### B. Manual test (raw write → read → clean-up, via q1)

```bash
KEY='<your-key>'; C="dokandar_smoke"

curl -fsS -X PUT "http://127.0.0.1:6333/collections/${C}" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"vectors":{"size":4,"distance":"Dot"}}'
curl -fsS -X PUT "http://127.0.0.1:6333/collections/${C}/points?wait=true" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"points":[
    {"id":1,"vector":[0.9,0.1,0.0,0.0],"payload":{"name":"চাল-rice"}},
    {"id":2,"vector":[0.1,0.9,0.0,0.0],"payload":{"name":"ডিম-egg"}},
    {"id":3,"vector":[0.0,0.0,0.9,0.1],"payload":{"name":"মাছ-fish"}}]}'
curl -fsS -X POST "http://127.0.0.1:6333/collections/${C}/points/count" -H "api-key: ${KEY}" \
  -H 'content-type: application/json' -d '{"exact":true}'                         # -> "count":3
curl -fsS "http://127.0.0.1:6333/collections/${C}/points/1" -H "api-key: ${KEY}"  # -> "name":"চাল-rice"
curl -fsS -X DELETE "http://127.0.0.1:6333/collections/${C}" -H "api-key: ${KEY}"
curl -fsS "http://127.0.0.1:6333/collections" -H "api-key: ${KEY}"               # -> ${C} gone (zero residue)
```

## Connection model

- **No single primary** — every peer (`q1 :6333`, `q2 :6343`, `q3 :6353`) accepts reads and writes; the
  Raft group replicates collection metadata everywhere and each shard's data to `replication_factor` peers.
- **gRPC** is published on q1 only (`:6334`). Point any client at any REST endpoint; the cluster routes to
  the shard owners internally.

## Status / logs

```bash
bash setup.sh status        # compose ps + each peer's /readyz + peer count
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/qdrant_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the three per-node data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/qdrant_cluster
```

## Notes

- **Browser UI:** `http://<host>:6333/dashboard` on any peer (the same collections appear everywhere) —
  paste the API key in its Settings panel.
- **p2p port (6335)** carries Raft/replication and has **no auth of its own** — it is **not published** to
  the host; keep it firewalled to the cluster (SG-fenced here). The API key only protects REST/gRPC.
- Dev posture: TLS off. Production = TLS, dedicated hosts/AZs per peer, and `on_disk` vectors +
  quantization for large indexes (see the native runbook's Appendix D).

## See also

- `../README.md` — using `test.sh` across all variants.
- `../01_native_single/` and `../03_docker_single/` — the single-node variants.
- `../../../dependencies/03_Databases_datastores/08_Qdrant_1.18/cluster_mode/` — the native (no-Docker)
  Raft HA runbook this mirrors.
