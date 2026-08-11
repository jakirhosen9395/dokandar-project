# Apache Kafka 4.3 — Docker Compose HA cluster (KRaft)

A 3-node Kafka cluster — **kafka-1 / kafka-2 / kafka-3**, each a **combined broker + controller** — with a
static KRaft controller quorum `[1,2,3]` (no ZooKeeper), via Docker Compose. PLAINTEXT (dev). Internal
topics are RF 3. Each node's data is on its own **host bind mount** so it **survives `docker compose down
-v`**. Tested on Ubuntu 26.04. Ships the **Provectus kafka-ui** browser console (sees all 3 brokers).

```text
        any broker is a valid bootstrap (clients discover the rest from metadata)
        ┌──────────────────┬──────────────────┬──────────────────┐
        ▼                  ▼                  ▼
 ┌────────────┐     ┌────────────┐     ┌────────────┐
 │  kafka-1   │     │  kafka-2   │     │  kafka-3   │   static KRaft quorum [1,2,3]
 │ data :9092 │◄───►│ data :9094 │◄───►│ data :9096 │   controllers :9093/:9095/:9097
 │ ctrl :9093 │     │ ctrl :9095 │     │ ctrl :9097 │   internal topics RF 3
 └────────────┘     └────────────┘     └────────────┘
        host networking — each node advertises host:<its data port> (reachable local AND cross-host)
```

## Topology

| Node | Container | Data port | Controller port | node.id |
| --- | --- | --- | --- | --- |
| kafka-1 | `dokandar_kafka_c1` | 9092 | 9093 | 1 |
| kafka-2 | `dokandar_kafka_c2` | 9094 | 9095 | 2 |
| kafka-3 | `dokandar_kafka_c3` | 9096 | 9097 | 3 |

The nodes use **host networking** and each advertises `host:<its data port>`, so the cluster is reachable
**locally and cross-host** with no port-mapping hairpin; the controller quorum voters likewise reference
`host:9093/9095/9097`. Set `KAFKA_ADVERTISED_HOST` to a reachable IP (empty => the host's first IP).
**Cluster formation is automatic** — the static quorum is baked into the compose env, so there is no
manual cluster-init / exec step; bringing the 3 nodes up forms the quorum.

Install / verify / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the shared cluster id, sets `KAFKA_ADVERTISED_HOST`, waits for all 3 brokers, runs the HA
acceptance, prints a connection summary); and **B. Manual** — raw `docker compose` + Ubuntu commands.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes** but never touches a **bind
mount**. Each node stores its log + KRaft metadata on a per-node bind mount under
`${DATA_ROOT}/kafka_cluster/{n1,n2,n3}`, and there is **no named volume**, so:

| Command | Containers | Data (`${DATA_ROOT}/kafka_cluster`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (cluster re-forms) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

Only `purge` (or `sudo rm -rf ${DATA_ROOT}/kafka_cluster`) deletes the topics + metadata.

## Prerequisites

Docker Engine + the Compose plugin (see `../03_docker_single/README.md` for the install). `setup.sh
acceptance` and `test.sh` need no host Kafka client — they run the bundled CLI inside the broker container
(`docker compose exec`) or an `apache/kafka:4.3.0` container.

## Configure

```bash
cp .env.example .env        # required — setup.sh errors if .env is missing; edit ports if 9092-9097 are taken
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `KAFKA_VERSION`, `KAFKA_ADVERTISED_HOST`,
`KAFKA_CLUSTER_ID`, `KAFKA_UI_PORT` (default `8080`), `KAFKA_UI_IMAGE`, `DATA_ROOT`. **Two REQUIRED
values** — the compose file refuses to start with either empty: `KAFKA_CLUSTER_ID`
(`${KAFKA_CLUSTER_ID:?…}`) and `KAFKA_ADVERTISED_HOST` (`${KAFKA_ADVERTISED_HOST:?…}`, used both in the
voters list and each node's advertised listener). `setup.sh up` generates/sets both; the manual path sets
them explicitly before `docker compose up`. The data ports `9092/9094/9096` + controller ports
`9093/9095/9097` are wired in the compose file (host networking) — change them there if taken.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up
```

`setup.sh up` prints **numbered step output** (1/4 … 4/4): configuration (generate the shared cluster id +
set `KAFKA_ADVERTISED_HOST`) → per-node data dirs + `docker compose up -d` (3 nodes + kafka-ui) → wait
until all 3 brokers answer → report the cluster state. It ends with a **connection summary** (3 bootstrap
servers `<host>:9092,<host>:9094,<host>:9096`, cluster id, the kafka-ui URL). The cluster id + advertised
host are saved to `.env`; a re-run reuses them.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file
cp .env.example .env

# 2. set the TWO required values (compose refuses an empty cluster id OR advertised host)
CID="$(docker run --rm apache/kafka:4.3.0 /opt/kafka/bin/kafka-storage.sh random-uuid | tr -d '\r' | tail -1)"
sed -i "s/^KAFKA_CLUSTER_ID=.*/KAFKA_CLUSTER_ID=${CID}/" .env
ADV="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -n "$ADV" ] || ADV=127.0.0.1
sed -i "s/^KAFKA_ADVERTISED_HOST=.*/KAFKA_ADVERTISED_HOST=${ADV}/" .env

# 3. create the three per-node bind-mount data dirs (apache/kafka runs as uid 1000)
sudo mkdir -p /data/kafka_cluster/n1 /data/kafka_cluster/n2 /data/kafka_cluster/n3
sudo chown -R 1000:1000 /data/kafka_cluster

# 4. bring up the whole cluster (3 nodes + kafka-ui; the static quorum forms automatically — no init step)
docker compose up -d

# 5. wait until all 3 brokers answer (the static quorum takes time to form), THEN verify the broker count
docker compose ps
for _ in $(seq 1 40); do
  n=0; for p in 9092 9094 9096; do docker compose exec -T kafka-1 /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "${ADV}:${p}" >/dev/null 2>&1 && n=$((n+1)); done
  [ "$n" = 3 ] && break; sleep 3
done
for p in 9092 9094 9096; do
  docker compose exec -T kafka-1 /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "${ADV}:${p}" >/dev/null 2>&1 && echo "node on :$p OK"
done
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "${ADV}:9092" | grep -c 'id:'   # -> 3
```

Open the **kafka-ui** console at `http://<KAFKA_ADVERTISED_HOST>:8080/` — it points at all 3 advertised
bootstrap endpoints, so it sees the whole cluster.

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh acceptance
```

Runs 3 criteria: **broker count == 3**; an **RF 3 topic shows ISR size 3** ({1,2,3}); and a message
**produced via node 1 (`:9092`) is consumed via node 2 (`:9094`)** — proving replication across nodes.
Cleans up the check topic after itself.

### B. Manual acceptance (produce on node 1 → consume on node 2 → assert replicated)

```bash
ADV="$(grep -E '^KAFKA_ADVERTISED_HOST=' .env | cut -d= -f2)"; T="ha_check_$$"

# (1) broker count == 3
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "${ADV}:9092" | grep -c 'id:'   # -> 3

# (2) an RF3 topic -> ISR size 3 (all 3 nodes in sync)
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server "${ADV}:9092" --create --topic "$T" --partitions 1 --replication-factor 3
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server "${ADV}:9092" --describe --topic "$T" | grep -oE 'Isr: [0-9,]+'   # -> Isr: 1,2,3

# (3) produce via node 1, consume via node 2 (replicated across nodes)
printf 'replicated-চাল\n' | docker compose exec -T kafka-1 /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "${ADV}:9092" --topic "$T"
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "${ADV}:9094" --topic "$T" --from-beginning --max-messages 1 --timeout-ms 15000
# -> replicated-চাল   (read off node 2 — proves cross-node replication + the UTF-8 round-trip)

# clean up
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server "${ADV}:9092" --delete --topic "$T"
```

## Test (the shared contract test, against the cluster)

### A. Scripted test

```bash
# from utility/05_Kafka/  (any node is a valid bootstrap; node 1 :9092 is the default)
bash test.sh 04_docker_cluster
bash test.sh "<host>:9092"     # or point at any node explicitly
```

Creates a throwaway `dokandar_kafkatest_*` topic, produces bilingual UTF-8 messages, consumes them back,
then deletes the topic and proves zero residue.

### B. Manual test (raw write → read → clean-up)

```bash
ADV="$(grep -E '^KAFKA_ADVERTISED_HOST=' .env | cut -d= -f2)"; T="dokandar_smoke_$$"
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server "${ADV}:9092" --create --topic "$T" --partitions 1 --replication-factor 3
printf 'rice\nচাল\noil\n' | docker compose exec -T kafka-1 /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "${ADV}:9092" --topic "$T"
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "${ADV}:9092" --topic "$T" --from-beginning --max-messages 3 --timeout-ms 20000
# -> rice / চাল / oil
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server "${ADV}:9092" --delete --topic "$T"
docker compose exec -T kafka-1 /opt/kafka/bin/kafka-topics.sh --bootstrap-server "${ADV}:9092" --list | grep -c "^${T}$"   # -> 0
```

## Connection model

- **Any broker is a valid bootstrap** — `<host>:9092` (node 1), `:9094` (node 2), `:9096` (node 3);
  producers/consumers discover the rest from cluster metadata. Off-box clients use the advertised host.
- **Internal topics are RF 3** (`offsets`/`txn` state replicated across all 3 nodes), so the cluster
  tolerates one node down without losing the consumer-offset or transaction log.

## Status / logs

```bash
bash setup.sh status        # docker compose ps + data-dir size
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all containers (3 brokers + kafka-ui) — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/kafka_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — per-node bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the three host data dirs (irreversible: topics + metadata gone)
docker compose down -v
sudo rm -rf /data/kafka_cluster
```

## Notes

- **Browser UI:** the Provectus **kafka-ui** at `http://<host>:8080` (host-networked; sees all 3 brokers,
  no auth — SG-fence it).
- PLAINTEXT, no auth (dev). Production: SASL_SSL + per-listener TLS.
- **Don't change `KAFKA_CLUSTER_ID` once the cluster has data** — KRaft binds each node's log dir to the
  id; `purge` first to start fresh.

## See also

- `../README.md` — using `test.sh` across all variants.
- `../03_docker_single/` — the single-node Docker variant.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../../../dependencies/04_Messaging_streaming/01_Apache_Kafka_4.3/cluster_mode/run_book.md` — the native
  (no-Docker) HA run book this mirrors.
