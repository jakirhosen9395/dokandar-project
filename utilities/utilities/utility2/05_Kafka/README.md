# Apache Kafka 4.3 — utility dependency

Kafka is DOKANDAR's durable event backbone — the transactional-outbox sink and the `dokandar.*` topic bus
that every service publishes/consumes (catalog, order, payment, review, …). Fully **KRaft** (ZooKeeper was
removed in Kafka 4.0). This folder holds the install variants plus a **shared test script** for all of them.

## Layout

```text
05_Kafka/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (kafka-CLI based) — works against ALL variants
├── 01_native_single/    ← native (no Docker), JDK + tgz, systemd, data in /data/kafka          [TESTED]
├── 03_docker_single/    ← Docker Compose (apache/kafka), bind-mounted data (survives `down -v`) [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA (3 combined broker+controller nodes, KRaft quorum)  [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-node cluster covers HA.)

> **Auth:** Kafka runs **PLAINTEXT** here — the platform's documented Kafka *dev* posture (the deps
> `01_Apache_Kafka_4.3` exemplar is PLAINTEXT too). Production uses **SASL_SSL**. Because the broker binds
> a network interface, restrict access at the firewall/security-group to trusted clients (these tests run
> over an AWS SG that only admits the test box).
>
> **Reachability:** `advertised.listeners` is set to the host's reachable IP (not localhost) so **remote**
> producers/consumers can connect — a client bootstraps to any broker, then connects to the addresses the
> broker advertises. Get this wrong and a cross-host client connects to the bootstrap but then fails.

## The shared test script — `test.sh`

Uses the **kafka CLI** tools, so the same script tests any variant. It creates a throwaway topic
`dokandar_kafkatest_<ts>`, **produces** messages (bilingual UTF-8), **consumes** them back, checks the
count + content, **describes** the topic, then **deletes** it and **proves zero residue**.

### How to run it

```bash
bash test.sh 01_native_single     # native (reads its .env)
bash test.sh 03_docker_single     # docker single-node (uses the published KAFKA_EXTERNAL_PORT)
bash test.sh "host:9092"          # cluster / ANY broker, incl. cross-host
KAFKA_BOOTSTRAP=host:9092 bash test.sh
```

### Run modes

The host's `/opt/kafka/bin` tools (native install) → **host mode**. Otherwise an `apache/kafka:<ver>`
Docker container with `--network host` → **docker mode** (so a client box needs only Docker). Neither →
exit `2`.

### Reading the result

`RESULT: PASS — test topic deleted, zero residue.` and exit `0` = every check passed and the cluster is
back to its pre-test state. Any failure prints the failing checks and exits `1`.

## See also

- `../README.md` — the utility-dependency overview (gating tiers, install order).
- `../../dependencies/04_Messaging_streaming/01_Apache_Kafka_4.3/` — the original install scripts (the
  project's 5-condition exemplar) + the `cluster_mode/run_book.md` native KRaft HA reference.
