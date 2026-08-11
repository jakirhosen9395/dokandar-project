# Apache Kafka — Docker Compose single-node (KRaft) + kafka-ui

Apache Kafka 4.3 in **KRaft mode** (single combined broker + controller, no ZooKeeper) + the **Provectus
kafka-ui** browser console, run via Docker Compose, configured from `.env`, with data on a **host bind
mount** so it **survives `docker compose down -v`**. Tested on Ubuntu 26.04. Design ported from the
`dokandar/utilities/components` `kafka/` reference (which uses `confluentinc/cp-kafka`); this uses
**`apache/kafka:4.3.0`** (DOKANDAR §8 pins 4.3; cp-kafka tops out at Kafka 4.0).

Three listeners (KRaft, no ZooKeeper):

| Listener | Port | Reached by | Advertised as |
| --- | --- | --- | --- |
| `PLAINTEXT` (internal) | `:29092` | containers on `dokandar_kafka_net` (the UI) | `kafka:29092` |
| `PLAINTEXT_HOST` (external) | `:9092` | host / native / off-box clients | `${KAFKA_EXTERNAL_HOST}:9092` |
| `CONTROLLER` | `:9093` | KRaft controller quorum (intra-cluster, not published) | — |

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates the KRaft cluster id, sets `KAFKA_EXTERNAL_HOST`, waits for the healthcheck, prints a
connection summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create the env + data
dir, generate the cluster id, bring it up by hand). Both produce the same container set.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the Kafka log on a bind mount
(`${DATA_ROOT}/kafka_docker` → the broker's `/var/lib/kafka/data`) and declares **no named volume at
all**, so:

| Command | Containers | Data (`${DATA_ROOT}/kafka_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (topics + offsets retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same topics. The *only* way to delete the data is `setup.sh purge`
(or `sudo rm -rf ${DATA_ROOT}/kafka_docker` by hand).

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

`test.sh` needs no host Kafka client — it falls back to running the bundled CLI inside an
`apache/kafka:4.3.0` container (`--network host`) when `/opt/kafka/bin` is absent.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host port / UI port if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `KAFKA_VERSION`, `KAFKA_UI_IMAGE`,
`KAFKA_EXTERNAL_HOST` (advertised to off-box clients), `KAFKA_CLUSTER_ID`, `KAFKA_EXTERNAL_PORT` (host port
→ container `:9092`, default `9092`), `KAFKA_UI_PORT` (default `8080`), `DATA_ROOT`. **`KAFKA_CLUSTER_ID`
is a REQUIRED secret** — the compose file refuses to start with it empty (`${KAFKA_CLUSTER_ID:?…}`).
`setup.sh up` generates it; the manual path generates it explicitly before `docker compose up`. **Leave
`KAFKA_EXTERNAL_HOST` empty** to let `setup.sh` fill it with this host's first IP (so off-box clients can
reach the advertised listener); set `localhost` for local-only dev.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                  # generates the cluster id, sets KAFKA_EXTERNAL_HOST, starts broker + UI
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3): configuration (generate the KRaft `CLUSTER_ID`,
set `KAFKA_EXTERNAL_HOST` to this host's IP) → create the host bind-mount data dir + `docker compose up -d`
(broker + kafka-ui) → wait for the broker healthcheck, verify the broker + UI. It ends with a **connection
summary** (off-box bootstrap `<host>:9092`, in-net bootstrap `kafka:29092`, cluster id, the kafka-ui URL).
The cluster id + external host are saved to `.env`; a re-run reuses them.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file
cp .env.example .env

# 2. generate the REQUIRED KRaft cluster id and write it into .env (compose refuses an empty id)
CID="$(docker run --rm apache/kafka:4.3.0 /opt/kafka/bin/kafka-storage.sh random-uuid | tr -d '\r' | tail -1)"
sed -i "s/^KAFKA_CLUSTER_ID=.*/KAFKA_CLUSTER_ID=${CID}/" .env

# 3. set the advertised host so off-box clients can reach the broker (or 'localhost' for local-only)
HOST_IP="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -n "$HOST_IP" ] || HOST_IP=localhost
sed -i "s/^KAFKA_EXTERNAL_HOST=.*/KAFKA_EXTERNAL_HOST=${HOST_IP}/" .env

# 4. create the host bind-mount data dir (apache/kafka runs as uid 1000)
sudo mkdir -p /data/kafka_docker && sudo chown -R 1000:1000 /data/kafka_docker

# 5. bring it up (reads .env for image tag, ports, cluster id, advertised host)
docker compose up -d

# 6. wait until the broker is healthy (kafka-ui only starts once it is), then verify broker + UI
for _ in $(seq 1 40); do [ "$(docker inspect -f '{{.State.Health.Status}}' dokandar_kafka_docker_single 2>/dev/null)" = healthy ] && break; sleep 2; done
docker compose ps                                              # kafka -> healthy
docker compose exec -T kafka /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server localhost:9092 | head -1
curl -fsS -o /dev/null -w '%{http_code}\n' "http://${HOST_IP}:8080/"   # kafka-ui -> 200
```

Open the **kafka-ui** console at `http://<KAFKA_EXTERNAL_HOST>:8080/` (no auth — SG-fence it).

## Test

The shared contract test creates a throwaway `dokandar_kafkatest_*` topic, produces bilingual UTF-8
messages, consumes them back, then deletes the topic and proves zero residue.

### A. Scripted test

```bash
# from utility/05_Kafka/
bash test.sh 03_docker_single

# cross-host (test server ≠ this host) — paste the bootstrap setup.sh printed:
bash test.sh "<host>:9092"
```

### B. Manual test (raw write → read → clean-up)

```bash
T="dokandar_smoke_$$"
# everything straight through the broker container (no host Kafka client needed)
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --create --topic "$T" --partitions 1 --replication-factor 1
printf 'rice\nচাল\noil\n' | docker compose exec -T kafka /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server localhost:9092 --topic "$T"
docker compose exec -T kafka /opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server localhost:9092 --topic "$T" --from-beginning --max-messages 3 --timeout-ms 20000
# -> rice / চাল / oil   (the চাল line proves the UTF-8 round-trip)

# delete the topic and prove zero residue
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --delete --topic "$T"
docker compose exec -T kafka /opt/kafka/bin/kafka-topics.sh --bootstrap-server localhost:9092 --list | grep -c "^${T}$"   # -> 0
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + host data-dir size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove containers (broker + kafka-ui) — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/kafka_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible: topics + offsets gone)
docker compose down -v
sudo rm -rf /data/kafka_docker
```

## Notes

- **Browser UI:** the Provectus **kafka-ui** at `http://<host>:8080` (no auth — SG-fence it). The
  **Brokers** page shows the single broker + cluster id; **Topics** lists topics with live messages and
  consumer-group lag.
- Off-box clients use `bootstrap.servers=<KAFKA_EXTERNAL_HOST>:9092`; same-network containers use
  `kafka:29092` (the internal `PLAINTEXT` listener the UI itself uses).
- **Don't change `KAFKA_CLUSTER_ID` once the broker has data** — KRaft binds the log dir to the id;
  `purge` first to start fresh.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the 3-node KRaft HA cluster variant.
