# Apache Kafka 4.3 — native single-node (no Docker)

A single Kafka node in **KRaft** mode (combined broker+controller, no ZooKeeper), the JDK + the Apache
tgz, managed by **systemd**, with data under **`/data/kafka`** (symlinked from `/var/lib/kafka`,
preserved on uninstall). PLAINTEXT (the platform's documented dev posture; production uses SASL_SSL);
`advertised.listeners` is set to the host IP so **remote** producers/consumers can reach it. Tested on
**Ubuntu 26.04 (resolute)**.

- **What runs:** a JDK (`openjdk-21-jre-headless`) + Apache Kafka `4.3.0` at `/opt/kafka`, one combined
  broker+controller node under the `kafka` systemd unit, running as the `kafka` system user.
- **Data:** `${DATA_ROOT}/kafka` (default `/data/kafka`), symlinked from `/var/lib/kafka` (KRaft
  `log.dirs`). Install is **non-destructive** (existing `/data/kafka` is reused, never wiped); uninstall
  **keeps the data**.
- **Browser UI:** none bundled — **Redpanda Console** / **kafka-ui** is the documented companion UI (a
  separate binary or Docker deploy pointed at the broker). The Docker variants ship kafka-ui inline.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates the KRaft cluster id, sets `advertised.listeners` to the host IP, prints a
connection summary); and **B. Manual** — raw copy-paste Ubuntu commands that run the exact same steps by
hand, no script. Both produce the same broker.

## Configure

```bash
cp .env.example .env        # optional — edit ports / advertised host
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `KAFKA_VERSION`, `KAFKA_NODE_ID`,
`KAFKA_BROKER_PORT` (default `9092`), `KAFKA_CONTROLLER_PORT` (default `9093`), `KAFKA_ADVERTISED_HOST`,
`KAFKA_CLUSTER_ID`, `DATA_ROOT`. **Leave `KAFKA_ADVERTISED_HOST` empty to auto-detect the host's first IP**
(`hostname -I`, good for same-VPC cross-host tests); set `127.0.0.1` for loopback-only, or a specific
IP/DNS for remote clients. `KAFKA_CLUSTER_ID` is generated once on first install and saved back to `.env`.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks): configuration → data dir (`/var/lib/kafka →
/data/kafka`, non-destructive) → install a JDK + Apache Kafka `4.3.0` to `/opt/kafka` → KRaft config
(`node.id`, `listeners`, `advertised.listeners` = host IP, `controller.quorum.voters`) +
`kafka-storage.sh format` → systemd unit + verify the broker answers. Ends with a **connection summary**
(bootstrap server, controller, data dir, CLI smoke test). The cluster id is generated once and saved to
`.env`. Idempotent: a re-run reuses the saved cluster id and skips a present `/opt/kafka`.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. **Do the
`/var/lib/kafka` → `/data` symlink *before* formatting storage**, so KRaft lands on `/data`, not the root
disk. Pick a reachable advertised host (loopback shown; use the host IP for off-box clients).

```bash
# 0. choose your settings (these are the setup.sh defaults)
KAFKA_VERSION=4.3.0
KAFKA_NODE_ID=1
KAFKA_BROKER_PORT=9092
KAFKA_CONTROLLER_PORT=9093
KAFKA_ADVERTISED_HOST="$(hostname -I 2>/dev/null | awk '{print $1}')"; [ -n "$KAFKA_ADVERTISED_HOST" ] || KAFKA_ADVERTISED_HOST=127.0.0.1

# 1. point the data dir at /data BEFORE formatting (so log.dirs lands on /data) — non-destructive
sudo mkdir -p /data/kafka
sudo rm -rf /var/lib/kafka && sudo ln -sfn /data/kafka /var/lib/kafka

# 2. a JDK (Kafka runs on the JVM) + download helpers
sudo apt-get update -y
sudo apt-get install -y openjdk-21-jre-headless wget ca-certificates   # fallback: default-jre-headless

# 3. fetch + unpack Apache Kafka 4.3.0 to /opt/kafka (archive.apache.org is the mirror fallback)
wget -qO /tmp/kafka.tgz "https://downloads.apache.org/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz" \
  || wget -qO /tmp/kafka.tgz "https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/kafka_2.13-${KAFKA_VERSION}.tgz"
sudo rm -rf /opt/kafka && sudo mkdir -p /opt/kafka
sudo tar -xzf /tmp/kafka.tgz -C /opt/kafka --strip-components=1 && rm -f /tmp/kafka.tgz
id kafka >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin kafka

# 4. KRaft config — edit /opt/kafka/config/server.properties (combined broker+controller)
SP=/opt/kafka/config/server.properties
sudo sed -i 's|^log.dirs=.*|log.dirs=/var/lib/kafka|' "$SP"
sudo sed -i "s|^node.id=.*|node.id=${KAFKA_NODE_ID}|" "$SP"
sudo sed -i "s|^listeners=.*|listeners=PLAINTEXT://:${KAFKA_BROKER_PORT},CONTROLLER://:${KAFKA_CONTROLLER_PORT}|" "$SP"
sudo sed -i "s|^advertised.listeners=.*|advertised.listeners=PLAINTEXT://${KAFKA_ADVERTISED_HOST}:${KAFKA_BROKER_PORT}|" "$SP"
sudo sed -i "s|^controller.quorum.voters=.*|controller.quorum.voters=${KAFKA_NODE_ID}@localhost:${KAFKA_CONTROLLER_PORT}|" "$SP"
sudo chown -R kafka:kafka /var/lib/kafka /opt/kafka

# 5. generate a cluster id + format the KRaft storage dir (single combined node)
KAFKA_CLUSTER_ID="$(/opt/kafka/bin/kafka-storage.sh random-uuid)"
sudo -u kafka env KAFKA_HEAP_OPTS='-Xms256m -Xmx512m' \
  /opt/kafka/bin/kafka-storage.sh format -t "$KAFKA_CLUSTER_ID" -c "$SP" --standalone --ignore-formatted

# 6. systemd unit + start
sudo tee /etc/systemd/system/kafka.service >/dev/null <<'UNIT'
[Unit]
Description=Apache Kafka (KRaft)
After=network.target
[Service]
User=kafka
Environment=KAFKA_HEAP_OPTS=-Xms256m -Xmx512m
ExecStart=/opt/kafka/bin/kafka-server-start.sh /opt/kafka/config/server.properties
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now kafka

# 7. wait for the broker to come up (the JVM takes a few seconds after start), then verify
systemctl is-active kafka                                                            # -> active
BS="${KAFKA_ADVERTISED_HOST}:${KAFKA_BROKER_PORT}"
for _ in $(seq 1 20); do /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "$BS" >/dev/null 2>&1 && break; sleep 2; done
/opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server "$BS" | head -1
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BS" --list
```

## Test

The contract/smoke test creates a throwaway `dokandar_kafkatest_*` topic, produces bilingual UTF-8
messages, consumes them back, then **deletes the topic and proves zero residue**.

### A. Scripted test (the shared contract test)

```bash
# from utility/05_Kafka/  (reads this variant's .env; uses /opt/kafka/bin host tools)
bash test.sh 01_native_single

# or pass the bootstrap explicitly (e.g. from another machine)
bash test.sh "<host>:9092"
```

Exits `0` and prints `RESULT: PASS` when every check passes and the test topic is gone.

### B. Manual test (raw write → read → clean-up)

```bash
BS="127.0.0.1:9092"                                  # or <KAFKA_ADVERTISED_HOST>:9092
T="dokandar_smoke_$$"

# create a topic, produce a bilingual UTF-8 message, consume it back
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BS" --create --topic "$T" --partitions 1 --replication-factor 1
printf 'rice\nচাল\noil\n' | /opt/kafka/bin/kafka-console-producer.sh --bootstrap-server "$BS" --topic "$T"
/opt/kafka/bin/kafka-console-consumer.sh --bootstrap-server "$BS" --topic "$T" --from-beginning --max-messages 3 --timeout-ms 20000
# -> rice / চাল / oil   (the চাল line proves the UTF-8 round-trip)

# delete the topic and prove zero residue
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BS" --delete --topic "$T"
/opt/kafka/bin/kafka-topics.sh --bootstrap-server "$BS" --list | grep -c "^${T}$"   # -> 0
```

## Status / logs

```bash
sudo bash setup.sh status        # service + broker reachability + data-dir size
# manual equivalents:
systemctl is-active kafka && /opt/kafka/bin/kafka-broker-api-versions.sh --bootstrap-server 127.0.0.1:9092 >/dev/null && echo reachable
journalctl -u kafka -n 80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
sudo bash setup.sh uninstall     # stop + remove /opt/kafka + the service; DATA PRESERVED at /data/kafka
sudo bash setup.sh purge         # uninstall + delete /data/kafka and the kafka user (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + disable, remove the unit, drop the /var/lib/kafka symlink + /opt/kafka (keeps the data on /data)
sudo systemctl stop kafka
sudo systemctl disable kafka
sudo rm -f /etc/systemd/system/kafka.service && sudo systemctl daemon-reload
sudo rm -f /var/lib/kafka        # this is the symlink, not the data
sudo rm -rf /opt/kafka

# (optional) remove the JDK if nothing else needs it
sudo apt-get purge -y openjdk-21-jre-headless && sudo apt-get autoremove --purge -y

# full wipe — ALSO delete the data + the kafka user (irreversible)
sudo rm -rf /data/kafka
sudo userdel kafka
```

## Notes

- **Browser UI:** none bundled — **Redpanda Console** / **Provectus kafka-ui** is the documented companion
  UI (a separate Go binary or a Docker container pointed at `<host>:9092`). The `03_docker_single` /
  `04_docker_cluster` variants run kafka-ui inline at `http://<host>:8080`.
- PLAINTEXT, no auth (dev). Production: SASL_SSL + per-listener TLS — SG-fence the broker meanwhile.
- **Don't change `KAFKA_CLUSTER_ID` once the broker has data** — KRaft binds the log dir to the id;
  `purge` first to start fresh.

## See also

- `../README.md` — using `test.sh` across all install variants.
- `../03_docker_single/` / `../04_docker_cluster/` — the Docker single-node and HA-cluster variants
  (both ship the kafka-ui browser console).
- `../../../dependencies/04_Messaging_streaming/01_Apache_Kafka_4.3/` — the original dependency-layer
  install scripts + the canonical manual-install reference these commands mirror.
