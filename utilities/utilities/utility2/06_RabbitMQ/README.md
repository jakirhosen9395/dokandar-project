# RabbitMQ 4.x — utility dependency

RabbitMQ is DOKANDAR's command/task broker — the per-service command queues `14-notification` and others
consume (alongside Kafka for events and NATS for fan-out). Quorum queues are the 4.x default durable type.
This folder holds the install variants plus a **shared test script** for all of them.

## Layout

```text
06_RabbitMQ/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (curl + Management HTTP API) — works against ALL variants
├── 01_native_single/    ← native (no Docker), systemd, env-file, data in /data/rabbitmq               [TESTED]
├── 03_docker_single/    ← Docker Compose (rabbitmq:4-management), bind-mounted data (survives down -v) [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA (3 nodes, shared Erlang cookie, quorum queues)             [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-node cluster covers HA.)

**Auth is ON** in every variant (an admin user; the stock `guest` user is deleted). Auto-generated complex
password saved to that variant's `.env` (chmod 600); a no-flag re-run reuses it, `--gen-password` rotates.
The **Management plugin** (built-in web UI + HTTP API) is enabled on **`:15672`** — a real browser UI.

## The shared test script — `test.sh`

Talks to the **Management HTTP API** (so it needs only **`curl`**), and the same script tests any variant.
It creates a throwaway **quorum queue** `dokandar_rabbittest_<ts>`, **publishes** a bilingual-UTF-8
message, **gets** it back, checks the payload, then **deletes** the queue and **proves zero residue**.

### How to run it

```bash
bash test.sh 01_native_single     # native (reads its .env)
bash test.sh 03_docker_single     # docker single-node
bash test.sh "http://user:pass@host:15672"   # cluster / ANY node, incl. cross-host
RABBITMQ_URL='http://user:pass@host:15672' bash test.sh
```

### Run modes

`curl` on `PATH` → **host mode**. No curl but Docker present → **docker mode** (`curlimages/curl`
`--network host`). Neither → exit `2`.

### Reading the result

`RESULT: PASS — test queue deleted, zero residue.` and exit `0` = every check passed and the broker is
back to its pre-test state. Any failure prints the failing checks and exits `1`.

## See also

- `../README.md` — the utility-dependency overview (gating tiers, install order).
- `../../dependencies/04_Messaging_streaming/02_RabbitMQ_4.3/` — the original install scripts + the
  `cluster_mode/run_book.md` native quorum-queue HA reference (3 nodes, failover with zero message loss).
