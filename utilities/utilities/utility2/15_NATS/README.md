# NATS JetStream — utility dependency

NATS JetStream 2.14 is DOKANDAR's **real-time messaging fabric** — the low-latency pub/sub + WebSocket
fan-out layer (ephemeral real-time signals; Kafka does the replayable event log, RabbitMQ the command
queue). This folder holds the install variants plus a **shared test script** for all of them.

## Layout

```text
15_NATS/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (JetStream KV, via the nats CLI) — works against ALL variants
├── 01_native_single/    ← native (no Docker), nats-server binary + systemd, JetStream on               [TESTED]
├── 03_docker_single/    ← Docker Compose, single node, JetStream store bind-mounted (survives down -v)  [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: 3 symmetric nodes meshed by routes, R3 streams             [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-node mesh covers HA.)

> **Auth & UI.** NATS is protected by a single **auth token** (`NATS_AUTH_TOKEN`; clients connect as
> `nats://<token>@host:4222`). Each variant's `setup.sh` **auto-generates** a 24-char token when `.env`'s is
> empty (or `--gen-token`), accepts `--token T`, and saves it to that variant's `.env` (chmod 600). NATS has
> **no browser UI** — `:8222` serves **JSON monitoring** (`/healthz`, `/varz`, `/jsz`, `/routez`). Tests run
> over an SG-fenced VPC.

## The shared test script — `test.sh`

Uses the **`nats` CLI** against JetStream. It confirms connectivity + JetStream, creates a throwaway **KV
bucket**, puts a bilingual-UTF-8 value, reads it back, then deletes the key + bucket and **proves zero
residue**.

### How to run it

```bash
bash test.sh 03_docker_single     # reads host/port/token from its .env
# or against ANY NATS (e.g. cross-host):
NATS_HOST=<host> NATS_AUTH_TOKEN=<token> bash test.sh
```

Client auto-selects: **host** `nats` if on PATH, else `nats` inside a **`natsio/nats-box`** Docker
container (`--network host`) — so a Docker variant tests with zero host packages.

### Reading the result

`RESULT: PASS — KV bucket created, value put/got/deleted, zero residue.` and exit `0` means JetStream + the
token work and the store is clean. Any failure prints the failing checks.

## See also

- `../README.md` — the utility-dependency overview.
- `../../dependencies/04_Messaging_streaming/03_NATS_JetStream_2.14/` — the original install script + the
  `cluster_mode/run_book.md` native HA reference (3 symmetric nodes, route mesh, R3 streams).
