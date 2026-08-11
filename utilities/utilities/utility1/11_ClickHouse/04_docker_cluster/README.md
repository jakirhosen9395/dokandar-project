# ClickHouse 26.3 LTS — Docker Compose, HA cluster (1 shard × 3 replicas + embedded Keeper)

Three `clickhouse/clickhouse-server:26.3` containers forming **one shard with three replicas**,
coordinated by an **embedded 3-node ClickHouse Keeper** quorum (no external ZooKeeper). Every node holds a
**full copy** of the data via **ReplicatedMergeTree**, so any node serves reads/writes and the loss of one
node loses neither data nor availability (Keeper quorum tolerates 1 down: majority 2 of 3). Tested on
Ubuntu 26.04, local + cross-host on AWS.

```text
        write any node                 read any node (full replica each)
              │                         ┌──────────────┬──────────────┐
              ▼                         ▼              ▼              ▼
       ┌────────────┐  ReplicatedMergeTree  ┌────────────┐   ┌────────────┐
       │    ch1     │ ◄──── Keeper ────►    │    ch2     │   │    ch3     │
       │ :8123 / RW │   (3-node quorum,     │ :8124 / RW │   │ :8125 / RW │
       │ :9000 TCP  │    embedded, no ZK)   │            │   │            │
       └────────────┘                       └────────────┘   └────────────┘
```

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the password, **renders the per-node config**, brings up all 3 nodes, runs the acceptance
gate); and **B. Manual** — raw `docker compose` + Ubuntu commands that reproduce the exact same render +
bring-up.

## How it works (and why the data survives `down -v`)

- Each node's **config + data are host bind mounts** under
  `${DATA_ROOT}/clickhouse_cluster/n{1,2,3}/{config.d,users.d,data}` (the `data` dir → the image's
  `/var/lib/clickhouse`). There is **no named volume**, so `docker compose down -v` keeps all three nodes'
  data **and** Keeper state, and they resync on `up`.
- The per-node `config.d`/`users.d` XML is **rendered onto the host before `compose up`** (Keeper
  `server_id`, the `{replica}=chN` macro, `remote_servers`, `zookeeper` pointing at the 3 Keepers, memory
  caps, and the `users.d` password). The compose file then bind-mounts those dirs in. **This render is the
  cluster init** — there is no `docker compose exec` init step.
- **Replication/cluster formation is automatic from that rendered config:** on `up` the three embedded
  Keepers auto-form a quorum, `system.clusters` shows the 3 replicas, and any `ON CLUSTER` DDL propagates
  through Keeper so a `ReplicatedMergeTree` table created on one node appears on all three.

| Command | Containers | Data + config (`${DATA_ROOT}/clickhouse_cluster`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (no named volume to remove) |
| `bash setup.sh up` | recreated | **reused** (re-render is idempotent) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

## Prerequisites

Docker Engine + Compose plugin (see `../03_docker_single/README.md` for the install). `test.sh` and the
acceptance gate need **no** host packages — they use `curl` (or a `curlimages/curl` container
automatically).

## Configure

```bash
cp .env.example .env        # set host ports if 8123–8125 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `CH_IMAGE` (the `26.3` tag),
`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, the per-node host ports `CH_HTTP1`/`CH_HTTP2`/`CH_HTTP3`
(`8123`/`8124`/`8125`) + `CH_TCP1` (`9000`, ch1 only), `CH_CLUSTER` (the cluster name `dokandar_1S_3R`),
`DATA_ROOT`. **Leave `CLICKHOUSE_PASSWORD` empty to auto-generate a complex (24-char) password** — it is
written identically into all three nodes' `users.d`. **A manual bring-up needs it set non-empty in `.env`**
(the manual render bakes it into each node's `users.d/dokandar-password.xml`), so the manual path sets one
explicitly. If `8123–8125` are taken on this host (e.g. a native or single-node ClickHouse is running),
change all three.

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up                              # generate pw, render configs, up 3 nodes, run acceptance
bash setup.sh up --password 'MyOwnSecret'     # or set the password explicitly
bash setup.sh up --gen-password               # rotate to a fresh generated password
```

`setup.sh up` (4 steps + acceptance): resolve creds → **render per-node config** (`render_node 1/2/3`) →
`docker compose up -d` (3 replicas + 3-node Keeper) → wait for the Keeper quorum + verify
`system.clusters` membership = 3 → **acceptance** (below). The password is identical on all 3 nodes. Ends
with a **credentials summary** (all three HTTP endpoints, native TCP, cluster name, user, password, the
`/play` URL). **Browser UI:** `http://<host>:8123/play` (the built-in SQL console; `:8124` / `:8125` too —
same replicated data on any node).

### B. Manual install (raw docker compose + per-node render)

The render is the cluster init — reproduce it before `up`. Everything below is exactly what
`setup.sh`'s `render_node` writes; the only per-node differences are the Keeper `server_id` (`${n}`) and
the `{replica}` macro (`ch${n}`).

```bash
# 1. create the env file and SET A PASSWORD (the render bakes it into each node's users.d)
cp .env.example .env
sed -i "s/^CLICKHOUSE_PASSWORD=.*/CLICKHOUSE_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. render config.d + users.d + the data dir for all three nodes
. ./.env; CDIR="${DATA_ROOT:-/data}/clickhouse_cluster"; CH_CLUSTER="${CH_CLUSTER:-dokandar_1S_3R}"
for n in 1 2 3; do
  nd="$CDIR/n$n"; sudo mkdir -p "$nd/config.d" "$nd/users.d" "$nd/data"

  # static on every node: network (HTTP 8123 / TCP 9000 / interserver 9009)
  sudo tee "$nd/config.d/00-network.xml" >/dev/null <<'XML'
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
    <interserver_http_port>9009</interserver_http_port>
</clickhouse>
XML

  # static: memory caps so 3 servers + 3 keepers fit one box. Do NOT lower background_pool_size
  # (default 16 is safe; 4 crash-loops the server — Code 36, pool below merge_tree reservation).
  sudo tee "$nd/config.d/01-memory.xml" >/dev/null <<'XML'
<clickhouse>
    <max_server_memory_usage>1500000000</max_server_memory_usage>
    <mark_cache_size>268435456</mark_cache_size>
</clickhouse>
XML

  # PER-NODE: embedded Keeper with this node's server_id; raft peers are all 3 nodes
  sudo tee "$nd/config.d/10-keeper.xml" >/dev/null <<XML
<clickhouse>
    <keeper_server>
        <tcp_port>9181</tcp_port>
        <server_id>${n}</server_id>
        <log_storage_path>/var/lib/clickhouse/coordination/log</log_storage_path>
        <snapshot_storage_path>/var/lib/clickhouse/coordination/snapshots</snapshot_storage_path>
        <coordination_settings>
            <operation_timeout_ms>10000</operation_timeout_ms>
            <session_timeout_ms>30000</session_timeout_ms>
        </coordination_settings>
        <raft_configuration>
            <server><id>1</id><hostname>ch1</hostname><port>9234</port></server>
            <server><id>2</id><hostname>ch2</hostname><port>9234</port></server>
            <server><id>3</id><hostname>ch3</hostname><port>9234</port></server>
        </raft_configuration>
    </keeper_server>
</clickhouse>
XML

  # static: point ClickHouse at the 3 embedded Keepers
  sudo tee "$nd/config.d/20-zookeeper.xml" >/dev/null <<'XML'
<clickhouse>
    <zookeeper>
        <node><host>ch1</host><port>9181</port></node>
        <node><host>ch2</host><port>9181</port></node>
        <node><host>ch3</host><port>9181</port></node>
    </zookeeper>
</clickhouse>
XML

  # the cluster topology: 1 shard, 3 replicas (uses CH_CLUSTER)
  sudo tee "$nd/config.d/30-remote-servers.xml" >/dev/null <<XML
<clickhouse>
    <remote_servers>
        <${CH_CLUSTER}>
            <shard>
                <internal_replication>true</internal_replication>
                <replica><host>ch1</host><port>9000</port></replica>
                <replica><host>ch2</host><port>9000</port></replica>
                <replica><host>ch3</host><port>9000</port></replica>
            </shard>
        </${CH_CLUSTER}>
    </remote_servers>
</clickhouse>
XML

  # PER-NODE: macros — {shard}=01, {replica}=chN (used by ReplicatedMergeTree zk paths)
  sudo tee "$nd/config.d/40-macros.xml" >/dev/null <<XML
<clickhouse>
    <macros>
        <shard>01</shard>
        <replica>ch${n}</replica>
        <cluster>${CH_CLUSTER}</cluster>
    </macros>
</clickhouse>
XML

  # the SQL-user password (identical on every node) + access management
  sudo tee "$nd/users.d/dokandar-password.xml" >/dev/null <<XML
<clickhouse>
    <users>
        <${CLICKHOUSE_USER:-default}>
            <password>${CLICKHOUSE_PASSWORD}</password>
            <access_management>1</access_management>
        </${CLICKHOUSE_USER:-default}>
    </users>
</clickhouse>
XML

  sudo chown -R 101:101 "$nd/data"   # uid 101 = clickhouse inside the image
done

# 3. bring up all three nodes (Keeper auto-forms its quorum; cluster forms from the rendered config —
#    NO manual exec init step)
docker compose up -d

# 4. wait until all three answer, then verify membership + a live Keeper session
for p in 8123 8124 8125; do
  until curl -fsS -o /dev/null "http://127.0.0.1:$p/ping"; do sleep 2; done; echo "node :$p up"
done
A='default:ChangeMe_StrongPassword'
printf 'SELECT count() FROM system.clusters WHERE cluster=%s' "'$CH_CLUSTER'" \
  | curl -s -u "$A" http://127.0.0.1:8123/ --data-binary @-                       # -> 3
printf "SELECT count() FROM system.zookeeper WHERE path='/'" \
  | curl -s -u "$A" http://127.0.0.1:8123/ --data-binary @-                       # -> >=1 (Keeper live)
```

## Verify the cluster (HA acceptance)

All three nodes are **read-write replicas** (not read-only standbys) — the acceptance proves a row written
on one node is readable on the others, the replicas are healthy, and a node-down failover loses nothing.

### A. Scripted acceptance

```bash
bash setup.sh accept
```

Runs the gate (also run automatically by `up`): (1) **Keeper quorum** live + `system.clusters` shows 3
replicas in `dokandar_1S_3R`; (2) a **ReplicatedMergeTree** table created `ON CLUSTER` — rows written on
**ch1** are read back on **ch2 and ch3** with UTF-8 (`চাল-rice`) intact; (3) `system.replicas` shows
`is_readonly=0`, `total_replicas=active_replicas=3`; (4) **failover** — stop **ch3**, a write to **ch1**
still succeeds and **ch2** serves the read, then ch3 restarts and **catches up**. Drops its test table on
exit.

### B. Manual acceptance (write on ch1 → read on ch2/ch3 → assert replication, then failover)

```bash
A='default:ChangeMe_StrongPassword'
q(){ printf '%s' "$2" | curl -s -u "$A" "http://127.0.0.1:$1/" --data-binary @-; }
C='dokandar_1S_3R'; T='ha_check'

# 1. create a ReplicatedMergeTree table ON CLUSTER (propagates to all 3 via Keeper)
q 8123 "CREATE TABLE default.${T} ON CLUSTER ${C} (id UInt64, name String) \
ENGINE=ReplicatedMergeTree('/clickhouse/tables/{shard}/${T}','{replica}') ORDER BY id"

# 2. write on ch1 ...
q 8123 "INSERT INTO default.${T} VALUES (1,'চাল-rice'),(2,'ডিম-egg')"
sleep 2
# ... read it back on ch2 AND ch3 (proves replication via Keeper)
q 8124 "SELECT count() FROM default.${T}"                 # -> 2
q 8125 "SELECT count() FROM default.${T}"                 # -> 2
q 8124 "SELECT name FROM default.${T} WHERE id=1"         # -> চাল-rice  (UTF-8 intact on ch2)

# 3. replicas healthy: is_readonly=0, total=active=3
q 8123 "SELECT is_readonly, total_replicas, active_replicas FROM system.replicas WHERE table='${T}'"   # -> 0  3  3

# 4. failover: stop ch3, write ch1, read ch2; then recover ch3 and watch it catch up
docker compose stop ch3; sleep 4
q 8123 "INSERT INTO default.${T} VALUES (3,'মাছ-fish')"
sleep 2
q 8124 "SELECT count() FROM default.${T}"                 # -> 3  (write+read survived ch3 down)
docker compose start ch3; sleep 8
q 8125 "SELECT count() FROM default.${T}"                 # -> 3  (ch3 caught up after restart)

# 5. clean up (drops on every node)
q 8123 "DROP TABLE IF EXISTS default.${T} ON CLUSTER ${C} SYNC"
```

## Test (the shared contract test, against ch1)

### A. Scripted test

```bash
# from utility/11_ClickHouse/
bash test.sh 04_docker_cluster
```

Reads this `.env` (`CH_HTTP1` = ch1's HTTP port), creates a throwaway `dokandar_test_*` database on ch1,
exercises the full contract (MergeTree create / insert / count / UTF-8 value / aggregate), then drops it
and proves zero residue.

### B. Manual test (raw write → read → clean-up on ch1)

```bash
A='default:ChangeMe_StrongPassword'; H='http://127.0.0.1:8123'
printf '%s' "CREATE DATABASE dokandar_smoke"                                  | curl -s -u "$A" "$H/" --data-binary @-
printf '%s' "CREATE TABLE dokandar_smoke.t (id UInt64, name String) ENGINE=MergeTree ORDER BY id" | curl -s -u "$A" "$H/" --data-binary @-
printf '%s' "INSERT INTO dokandar_smoke.t VALUES (1,'চাল-rice'),(2,'ডিম-egg'),(3,'মাছ-fish')"      | curl -s -u "$A" "$H/" --data-binary @-
printf '%s' "SELECT count() FROM dokandar_smoke.t"                            | curl -s -u "$A" "$H/" --data-binary @-   # -> 3
printf '%s' "SELECT name FROM dokandar_smoke.t WHERE id=1"                    | curl -s -u "$A" "$H/" --data-binary @-   # -> চাল-rice
printf '%s' "DROP DATABASE dokandar_smoke"                                    | curl -s -u "$A" "$H/" --data-binary @-
printf '%s' "SELECT count() FROM system.databases WHERE name='dokandar_smoke'"| curl -s -u "$A" "$H/" --data-binary @-   # -> 0 (zero residue)
```

## Connection model

- **Read/write any node** (`:8123` ch1, `:8124` ch2, `:8125` ch3) — every node is a full
  `ReplicatedMergeTree` replica, so the same data appears everywhere. ch1 also publishes native TCP
  `:9000`.
- For HA clients put a load balancer / `remote()` in front, or list all three hosts; a single node down
  is tolerated (Keeper majority 2 of 3).

## Status / logs

```bash
bash setup.sh status        # compose ps + each node's HTTP /ping + host data size
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=100 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data + config PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/clickhouse_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data + config are PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete all three nodes' config + data (irreversible)
docker compose down -v
sudo rm -rf /data/clickhouse_cluster
```

## Notes

- **Browser UI:** the built-in **/play** SQL console at `http://<host>:8123/play` on any node (`:8124` /
  `:8125` too) — the same replicated data appears everywhere. Enter the user/password in the top-right
  fields.
- **Memory:** the rendered config caps `max_server_memory_usage` so 3 servers + 3 keepers fit one box. It
  deliberately **does not** lower `background_pool_size` (the default 16 is safe; 4 crash-loops the
  server — Code 36, pool below the merge_tree reservation thresholds).
- Dev posture: TLS off, one shard. Production = TLS, dedicated hosts/AZs per replica, and (for scale) add
  shards per the native runbook's Appendix A.

## See also

- `../README.md` — using `test.sh` across all variants.
- `../03_docker_single/` — the single-node Docker variant; `../01_native_single/` — the no-Docker,
  systemd-native variant.
- `../../../dependencies/03_Databases_datastores/07_ClickHouse_26.3_LTS/cluster_mode/` — the native
  (no-Docker) Keeper-coordinated HA runbook this mirrors (incl. Appendix A sharding).
