# RustFS — Docker Compose HA cluster (4-node distributed erasure set)

Four `rustfs/rustfs` containers forming **one distributed erasure set** (4 nodes × 1 drive) — **S3-compatible
object storage** (replaces MinIO; the DOKANDAR object-store exit path). Every node runs the same
`RUSTFS_VOLUMES` list (`http://rustfs1..4:9000/data`); each serves its local `/data` and erasure-codes
objects across all four, so the namespace **survives the loss of one node**. Clients connect to **any** node
— one shared, S3-compatible namespace. Tested on Ubuntu 26.04 (verified live on AWS, local + cross-host).

```text
            writes/reads to ANY node → one shared, erasure-coded namespace
   ┌──────────────┬──────────────┬──────────────┬──────────────┐
   ▼              ▼              ▼              ▼
┌────────┐    ┌────────┐    ┌────────┐    ┌────────┐
│rustfs1 │◄──►│rustfs2 │◄──►│rustfs3 │◄──►│rustfs4 │   one distributed
│:9000 RW│    │:9002 RW│    │internal│    │internal│   erasure set
│:9001 UI│    │        │    │        │    │        │   (survives 1 node down)
└────────┘    └────────┘    └────────┘    └────────┘
  published     published      no published port
```

node1 publishes the S3 API (`:9000`) + console (`:9001`); node2 publishes its S3 API (`:9002`, for the
read-there proof); nodes 3–4 are internal (no published port). Per-node objects + logs are **host bind
mounts** so they **survive `docker compose down -v`**. Containers run as **uid 10001**.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(auto-generates the S3 keys, brings up all 4 nodes, runs the acceptance gate, prints a connection summary);
and **B. Manual** — raw `docker compose` + Ubuntu commands.

## How it works (and why the objects survive `down -v`)

- Each node stores objects + logs on **host bind mounts** at `${DATA_ROOT}/rustfs_cluster/n{1,2,3,4}/data`
  (→ `/data`) and `…/n{1,2,3,4}/logs` (→ `/logs`). There is **no named volume**, so `docker compose down -v`
  keeps all four nodes' data and they resync on `up`.
- The cluster is formed **declaratively** by the identical `RUSTFS_VOLUMES` list on every node — the four
  nodes auto-discover each other and form one erasure set on first start. **There is no manual
  cluster-init step:** `docker compose up -d` is all that's needed; `setup.sh up` adds the wait + acceptance
  gate on top.

## Prerequisites

Docker Engine + Compose plugin (see `../03_docker_single/README.md` for the install). The acceptance gate
and `test.sh` use the `mc` S3 client, which runs in a throwaway `minio/mc` Docker container — no host
package needed.

## Configure

```bash
cp .env.example .env        # set host ports if 9000/9001/9002 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `RUSTFS_IMAGE`, `RUSTFS_ACCESS_KEY`,
`RUSTFS_SECRET_KEY` (**identical on all 4 nodes**), and the host ports `RFS_API1` (node1 S3, default 9000) /
`RFS_CONSOLE1` (node1 console, 9001) / `RFS_API2` (node2 S3, 9002), plus `DATA_ROOT`. **If those ports are
taken** (e.g. a native or single-node RustFS is already running), change them. **Leave
`RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY` empty to auto-generate AWS-shape keys** — `setup.sh up` fills them
before `docker compose up`. **A direct `docker compose up` needs both keys set non-empty in `.env`** (the
compose file declares them `:?set in .env` on every node), so the manual path sets them explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                              # auto-generates the S3 keys, brings up 4 nodes, runs acceptance
bash setup.sh up --gen-keys                   # rotate both keys
bash setup.sh up --access KEY --secret KEY    # set fixed keys explicitly
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3): resolves the keys (saved to `.env`), creates the
four `${DATA_ROOT}/rustfs_cluster/n{1,2,3,4}/{data,logs}` bind dirs and chowns them to **uid 10001**,
`docker compose up -d` (the 4 nodes form the erasure set), polls node1 `/health` until `200`, verifies S3
on node1 + node2 (`mc ls`), then runs **acceptance** (below). It ends with a **connection summary** (both
S3 endpoints, access/secret keys, node1 console URL, the cross-host test command); the keys are shown once
and saved to `.env`. A no-flag re-run **reuses** the stored keys.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET BOTH KEYS (compose declares them :?set in .env on every node)
cp .env.example .env
sed -i "s/^RUSTFS_ACCESS_KEY=.*/RUSTFS_ACCESS_KEY=ChangeMe_AccessKey/" .env
sed -i "s/^RUSTFS_SECRET_KEY=.*/RUSTFS_SECRET_KEY=ChangeMe_StrongSecretKey/" .env

# 2. create the four per-node host bind-mount dirs and own them to the container's uid (10001)
sudo mkdir -p /data/rustfs_cluster/n{1,2,3,4}/data /data/rustfs_cluster/n{1,2,3,4}/logs
sudo chown -R 10001:10001 /data/rustfs_cluster
sudo chmod -R 755 /data/rustfs_cluster

# 3. bring up the whole cluster (all 4 nodes auto-form the erasure set from RUSTFS_VOLUMES — no manual init)
docker compose up -d

# 4. wait until the nodes are healthy, then verify S3 on node1 + node2
watch -n2 'docker compose ps'      # Ctrl-C once rustfs1..4 are all "healthy"/"Up"
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/health   # node1 -> 200
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9002/health   # node2 -> 200
docker run --rm -i --network host \
  -e MC_HOST_n="http://ChangeMe_AccessKey:ChangeMe_StrongSecretKey@127.0.0.1:9000" \
  minio/mc:latest --no-color ls n                                       # node1 ListBuckets OK
```

> **Browser console:** once up, open `http://<host>:9001` (node1 console) and log in with the access/secret
> keys — the shared buckets appear from any node.

## Verify the cluster (HA acceptance)

The acceptance gate proves the three HA properties: (1) all 4 nodes up + S3 reachable; (2) an object
**written via node1 is read back via node2** (the shared erasure-coded namespace); (3) **failover** — with
**node4 stopped**, a new object still PUTs/GETs and the old object stays readable, then node4 rejoins. It
cleans up its probe bucket after itself.

### A. Scripted acceptance

```bash
bash setup.sh accept        # re-run the acceptance gate (also run automatically by `up`)
```

### B. Manual acceptance (write on node1 → read on node2 → node-down failover)

```bash
# mc helper against a node by host port:  MC <port> <mc-subcommand...>
MC(){ local p="$1"; shift; docker run --rm -i --network host \
  -e MC_HOST_n="http://ChangeMe_AccessKey:ChangeMe_StrongSecretKey@127.0.0.1:${p}" \
  minio/mc:latest --no-color "$@"; }
B="accept-$(date +%s)"

# (1) all 4 containers up
docker compose ps                                                # rustfs1..4 -> Up/healthy

# (2) WRITE via node1 (:9000), READ via node2 (:9002) — proves the shared erasure-coded namespace
MC 9000 mb --ignore-existing "n/$B"
printf '%s' 'replicated-চাল' | MC 9000 pipe "n/$B/probe.txt"
sleep 2
MC 9002 cat "n/$B/probe.txt"                                     # -> replicated-চাল  (written on node1)

# (3) FAILOVER — stop node4, a new object still PUTs/GETs and the old one stays readable (erasure quorum)
docker compose stop rustfs4 ; sleep 5
printf '%s' 'survived-node4-down' | MC 9000 pipe "n/$B/probe2.txt"
MC 9000 cat "n/$B/probe2.txt"                                    # -> survived-node4-down  (node4 down)
MC 9002 cat "n/$B/probe.txt"                                     # -> replicated-চাল       (still readable)
docker compose start rustfs4 ; sleep 4                           # node4 rejoins + heals

# clean up the probe bucket (zero residue)
MC 9000 rm --recursive --force "n/$B" ; MC 9000 rb --force "n/$B"
```

## Test (the shared contract test, against node 1)

The shared contract test (via the `mc` S3 client) lists buckets (auth), creates a **throwaway** bucket,
PUTs 2 bilingual-UTF-8 objects, GETs them back byte-identical, asserts the list count, stats, server-side
copies, then removes everything and proves **zero residue**.

### A. Scripted test

```bash
# from utility/10_RustFS/  (reads creds + node1 port from this variant's .env)
bash ../test.sh 04_docker_cluster

# cross-host (test client ≠ this host) — paste the keys setup.sh printed:
RUSTFS_HOST=<host> RUSTFS_API_PORT=9000 RUSTFS_ACCESS_KEY=<ak> RUSTFS_SECRET_KEY=<sk> bash ../test.sh
```

### B. Manual test (raw write → read → clean-up via node 1)

```bash
export MC_HOST_n="http://ChangeMe_AccessKey:ChangeMe_StrongSecretKey@127.0.0.1:9000"
MC(){ docker run --rm -i --network host -e MC_HOST_n="$MC_HOST_n" minio/mc:latest --no-color "$@"; }

MC mb n/dokandar-smoke                                            # create a throwaway bucket
printf '%s' 'hello-চাল-dokandar' | MC pipe n/dokandar-smoke/probe.txt   # PUT a UTF-8 object
MC cat n/dokandar-smoke/probe.txt                                # GET it back -> hello-চাল-dokandar
MC rm --recursive --force n/dokandar-smoke                       # remove the object …
MC rb --force n/dokandar-smoke                                   # … and the bucket (zero residue)
MC ls n                                                          # -> dokandar-smoke is gone
```

## Connection model

- **Any node serves the same shared, erasure-coded namespace** — write to node1 (`:9000`) or node2
  (`:9002`), read from either; objects are erasure-coded across all four drives.
- Production = dedicated hosts/AZs per node, TLS, and an LB fronting a **single stable S3 endpoint** across
  the nodes (nodes 3–4 are internal here; in prod every node would be reachable behind the LB).

## Status / logs

```bash
bash setup.sh status        # compose ps + per-node S3 /health + host data size
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 4 containers — objects PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/rustfs_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted objects are PRESERVED either way
docker compose down               # objects kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the four per-node host data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/rustfs_cluster
```

## Notes

- **Browser UI:** `http://<host>:9001` (node1 console — the shared buckets appear from any node).
- Distributed RustFS is a **beta** train; pin `RUSTFS_IMAGE` deliberately and re-test on upgrade.

## See also

- `../README.md` — using `test.sh` across all variants.
- `../03_docker_single/` — the single-container variant; `../01_native_single/` — the no-Docker, native
  systemd variant.
