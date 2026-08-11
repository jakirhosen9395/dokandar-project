# Redis 8 — Docker Compose, HA cluster (Redis Cluster)

A 6-node **Redis Cluster** via Docker Compose — **3 primaries + 3 replicas** — sharding the 16384 hash
slots, with auth (`requirepass` + `masterauth`, the ACL `default` user) and **AOF** persistence. Each
node's data is on its own **host bind mount** (survives `docker compose down -v`). Tested on Ubuntu 26.04.

```text
                   16384 hash slots, auto-sharded across 3 primaries
   ┌──────────────┐      ┌──────────────┐      ┌──────────────┐
   │  redis-1 P   │      │  redis-2 P   │      │  redis-3 P   │   primaries  :7001-7003
   │   :7001      │      │   :7002      │      │   :7003      │
   └──────┬───────┘      └──────┬───────┘      └──────┬───────┘
          │ replicates          │ replicates          │ replicates
   ┌──────▼───────┐      ┌──────▼───────┐      ┌──────▼───────┐
   │  redis-4 R   │      │  redis-5 R   │      │  redis-6 R   │   replicas   :7004-7006
   │   :7004      │      │   :7005      │      │   :7006      │
   └──────────────┘      └──────────────┘      └──────────────┘
        cluster bus on 17001-17006 · host networking · announce-ip = host's reachable IP
```

(Which physical node is a primary vs replica is assigned by `--cluster create` and can change on
failover.) Failover is **automatic** — a replica is promoted when its primary is lost (Redis Cluster
gossip + failover vote).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the password, brings up 6 nodes, forms the cluster, waits for `cluster_state:ok`, prints a
credentials summary); and **B. Manual** — raw `docker compose` + `redis-cli --cluster` commands.

## Topology

| Node | Container | Port (bus) | Role |
| --- | --- | --- | --- |
| redis-1 | `dokandar_redis_c1` | 7001 (17001) | primary |
| redis-2 | `dokandar_redis_c2` | 7002 (17002) | primary |
| redis-3 | `dokandar_redis_c3` | 7003 (17003) | primary |
| redis-4 | `dokandar_redis_c4` | 7004 (17004) | replica |
| redis-5 | `dokandar_redis_c5` | 7005 (17005) | replica |
| redis-6 | `dokandar_redis_c6` | 7006 (17006) | replica |

## Reachability (announce IP)

The nodes use **host networking** and announce **`cluster-announce-ip` = the host's reachable IP** (set by
`setup.sh` from `hostname -I`, saved to `.env` as `CLUSTER_ANNOUNCE_IP`), so a client — local **or**
cross-host — can follow `MOVED`/`ASK` redirects to any node. Without it, nodes would announce internal
addresses unreachable from outside. Ports `7001-7006` (data) **and** `17001-17006` (cluster bus) must be
reachable from clients that follow redirects.

## How it works (cluster init is NOT automatic)

- Each node stores its keyspace + `nodes.conf` on a **host bind mount** at the container's `/data`:
  `${DATA_ROOT}/redis_cluster/{n1..n6}`. There is **no named volume**, so `docker compose down -v` keeps
  all six nodes' data and the cluster re-forms on the next `up`.
- `docker compose up -d` starts 6 cluster-enabled `redis:8` nodes, but **forming the cluster is an
  explicit step** — `setup.sh up` runs `redis-cli --cluster create … --cluster-replicas 1 --cluster-yes`
  once the 6 nodes answer (idempotent — skipped if `cluster_state:ok` already). On a re-`up` of an already
  formed cluster the persisted `nodes.conf` restores the topology, so the create step is skipped.

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

`test.sh` and the manual commands below run through the containers, so no host `redis-cli` is required.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Vars: `REDIS_VERSION`, `REDIS_PASSWORD`
(`requirepass` + `masterauth`), `CLUSTER_ANNOUNCE_IP`, `DATA_ROOT`. **Leave `REDIS_PASSWORD` and
`CLUSTER_ANNOUNCE_IP` empty to auto-fill** — `setup.sh up` generates the password and derives the announce
IP from `hostname -I` before forming the cluster, then saves both. **A direct `docker compose up` needs
both set non-empty in `.env`** (the compose file requires them — `--requirepass ${REDIS_PASSWORD:?…}` and
`--cluster-announce-ip ${CLUSTER_ANNOUNCE_IP:?…}`), so the manual path sets them explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                  # auto-generates the password, brings up 6 nodes, forms the cluster
bash setup.sh up --password 'MyOwnSecret'   # or set the password explicitly
bash setup.sh up --gen-password   # rotate the password
```

`setup.sh up` (4 steps): configuration (announce-ip) → per-node data dirs (`chown` to uid 999) +
`docker compose up` (6 nodes, host network) → **form the cluster** with
`redis-cli --cluster create … --cluster-replicas 1 --cluster-yes` (idempotent — skipped if already
`cluster_state:ok`) → wait for `cluster_state:ok` + print `cluster_known_nodes`/`cluster_size`. Ends with
the **credentials summary** (all 6 endpoints, the `default` user, password, `redis-cli -c` connect command).

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET the password + the announce IP (compose requires both non-empty)
cp .env.example .env
sed -i "s/^REDIS_PASSWORD=.*/REDIS_PASSWORD=ChangeMe_StrongPassword/" .env
ANNOUNCE_IP=$(hostname -I | awk '{print $1}')        # the host's reachable IP (override if needed)
sed -i "s/^CLUSTER_ANNOUNCE_IP=.*/CLUSTER_ANNOUNCE_IP=${ANNOUNCE_IP}/" .env

# 2. create all 6 per-node host bind-mount data dirs + chown to uid 999 (the redis user in the image)
sudo mkdir -p /data/redis_cluster/n1 /data/redis_cluster/n2 /data/redis_cluster/n3 \
              /data/redis_cluster/n4 /data/redis_cluster/n5 /data/redis_cluster/n6
sudo chown -R 999:999 /data/redis_cluster

# 3. bring up the 6 nodes (NOT yet a cluster — they start standalone)
docker compose up -d
docker compose ps                                     # wait until all 6 are Up

# 4. FORM the cluster explicitly — 3 primaries + 3 replicas (this is the step that is NOT automatic)
PW='ChangeMe_StrongPassword'
docker compose exec -T redis-1 redis-cli -a "$PW" --no-auth-warning --cluster create \
  ${ANNOUNCE_IP}:7001 ${ANNOUNCE_IP}:7002 ${ANNOUNCE_IP}:7003 \
  ${ANNOUNCE_IP}:7004 ${ANNOUNCE_IP}:7005 ${ANNOUNCE_IP}:7006 \
  --cluster-replicas 1 --cluster-yes

# 5. verify the cluster converged (should print cluster_state:ok, cluster_size:3)
docker compose exec -T redis-1 redis-cli -a "$PW" --no-auth-warning -p 7001 cluster info \
  | grep -E 'cluster_state|cluster_known_nodes|cluster_size'
```

> **No browser UI** — Redis ships no web console (use `redis-cli -c` / the RedisInsight desktop app).

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh acceptance
```

Asserts the 3 criteria: (1) `cluster_state:ok`, 6 known nodes, `cluster_size:3` (3 primaries); (2) lists
the primaries/replicas; (3) a key written via one node is **read back through a different node** (the slot
redirect works), then cleans the key up.

### B. Manual acceptance (write on one node → read via another → assert routing)

```bash
PW='ChangeMe_StrongPassword'
IP=$(awk -F= '/^CLUSTER_ANNOUNCE_IP=/{print $2}' .env)

# (1) cluster state + size
docker compose exec -T redis-1 redis-cli -a "$PW" --no-auth-warning -p 7001 cluster info \
  | grep -E 'cluster_state|cluster_known_nodes|cluster_size'      # -> cluster_state:ok ... cluster_size:3

# (2) primaries vs replicas
docker compose exec -T redis-1 redis-cli -a "$PW" --no-auth-warning -p 7001 cluster nodes \
  | awk '{print $2, $3}'

# (3) write via one node, read it back through a DIFFERENT node (-c follows the MOVED redirect)
docker compose exec -T redis-1 redis-cli -c -a "$PW" --no-auth-warning -h "$IP" -p 7001 set ha_check 'replicated-চাল'
docker compose exec -T redis-1 redis-cli -c -a "$PW" --no-auth-warning -h "$IP" -p 7002 get ha_check   # -> replicated-চাল
docker compose exec -T redis-1 redis-cli -c -a "$PW" --no-auth-warning -h "$IP" -p 7001 del ha_check    # clean up
```

## Test (the shared contract test, against the cluster)

The shared contract test uses a **hash-tagged** key prefix `{dokandar_test_<ts>}` so all its keys land on
one slot (cluster-safe multi-key cleanup), exercises strings / counter / TTL / list / hash / set /
sorted-set + bilingual UTF-8 (`চাল`), then deletes them all and proves zero residue.

### A. Scripted test

```bash
# from utility/04_Redis/  (point it at any node; -c makes it cluster-aware)
bash test.sh "redis://default:<your-password>@<announce-ip>:7001"
```

### B. Manual test (raw write → read → clean-up via the cluster)

```bash
PW='ChangeMe_StrongPassword'
IP=$(awk -F= '/^CLUSTER_ANNOUNCE_IP=/{print $2}' .env)
RC="docker compose exec -T redis-1 redis-cli -c -a $PW --no-auth-warning -h $IP -p 7001"
$RC set '{dokandar_smoke}:str' 'hello-চাল-dokandar'
$RC get '{dokandar_smoke}:str'      # -> hello-চাল-dokandar
$RC del '{dokandar_smoke}:str'      # -> (integer) 1
$RC exists '{dokandar_smoke}:str'   # -> (integer) 0  (zero residue)
```

## Connection model

- **Any node accepts reads/writes for the slots it owns**; use `redis-cli -c` (cluster mode) or a
  cluster-aware client library so `MOVED`/`ASK` redirects are followed automatically to the right node.
- **Writes go to the primary** owning the key's slot; replicas serve replicated copies (read with
  `READONLY` / a cluster client's replica-read mode).

## Failover (automatic)

If a primary is lost, its replica is promoted automatically by the cluster (gossip + failover vote) — no
manual `pg_promote`-style step. Watch it with:

```bash
docker compose exec -T redis-1 redis-cli -a '<your-password>' --no-auth-warning -p 7001 cluster nodes
# kill a primary container, then re-check — its replica flips to master:
docker compose stop redis-1        # (example) take a node down
docker compose start redis-1       # bring it back — it rejoins as a replica
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + host data size
bash setup.sh logs          # follow all node logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 6 containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/redis_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mounts survive -v

# full wipe — ALSO delete the six host data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/redis_cluster
```

## Notes

- **Browser UI:** none.
- Per-node data are **host bind mounts** under `${DATA_ROOT}/redis_cluster/{n1..n6}` (AOF + `nodes.conf`),
  so `down`/`down -v` preserve them and the cluster re-forms on the next `up`. Only `purge` deletes them.

## See also

- `../README.md` — using `test.sh` across all variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../03_docker_single/` — the Docker Compose single-node variant.
- `../../../dependencies/03_Databases_datastores/04_Redis_8/cluster_mode/run_book.md` — the native
  (no-Docker) 6-node Redis Cluster run book this mirrors (failover with zero key loss).
