# devops-dokandar-infra — the DOKANDAR utility library + fleet orchestrator

One self-contained, **learner-friendly** folder per infrastructure utility (a Docker Compose
with a comment above every block, a script that generates credentials for you, and a contract
test that proves it works and leaves zero residue) — plus **one fleet orchestrator**
(`setup.sh` in this folder) that drives the ENTIRE fleet from a single command on your laptop:
it SSHes into each server, ships this folder there if missing, boots every utility one at a
time, and prints one combined credentials sheet with public URLs you can paste anywhere.


## Setup Docker in Ubuntu Linux
```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker

sudo systemctl enable docker.service
sudo systemctl enable containerd.service
```


## The fleet, in one command

```bash
bash setup.sh                    # everything, on every server, up (default target=all)
bash setup.sh all creds          # ONE combined credential sheet for the whole fleet
bash setup.sh all status         # what is running where
bash setup.sh all test           # run every utility's contract test
bash setup.sh all down           # stop everything (data KEPT)
bash setup.sh all purge          # stop + DELETE data (explicit data-loss action)

bash setup.sh infra1 up          # just the observability/messaging box
bash setup.sh infra2 test        # contract-test every datastore tool
bash setup.sh postgresql status  # one utility — auto-routed to the server that owns it
bash setup.sh kafka logs         # recent logs of one utility
bash setup.sh redis restart      # restart one utility
```

Positional tokens (`target`, `variant`, `action`) are recognised by what they are — any order
works. `bash setup.sh --help` shows everything.

## Servers (the host map)

Public IPs are **dynamic** (no Elastic IP). When they change, edit the two lines at the top of
`setup.sh` (or `export INFRA1_HOST=... INFRA2_HOST=...`):

| Logical server | Role | Current IP |
|---|---|---|
| **infra1** | observability + messaging (elastic-apm-stack, kafka, schema-registry, rabbitmq, redis) | `52.77.234.48` |
| **infra2** | datastores (postgresql, timescaledb, mongodb, opensearch, clickhouse, neo4j, rustfs, scylladb) | `52.77.234.48` |

Right now **both point at the same box — single-machine mode**: the canonical port map (below)
guarantees all 13 utilities co-exist with zero collisions, so one 8 GB machine can carry the
whole fleet (≈80–90 % RAM when warm; every service is `mem_limit`-capped). To split back onto
two boxes, just point `INFRA1_HOST`/`INFRA2_HOST` at two different IPs — nothing else changes.

The orchestrator reaches servers as `ubuntu` with the key in `SSH_KEY` (default
`/home/jakir/final-year-project/test.pem`). If the folder is missing on a server it is shipped
automatically (rsync, tar fallback) — a single laptop command fully provisions a fresh box.

## Canonical host-port map — the no-conflict guarantee

Every utility's `.env` defaults to exactly these host ports. The orchestrator's preflight
verifies the live values still match and **fails loudly** (naming both offenders) if anything
diverges. Container-internal ports stay default; only the published host port is fixed.

| Utility | Service | Host port | Moved? why |
|---|---|---|---|
| PostgreSQL | postgres | 5432 | |
| TimescaleDB | postgres | **5433** | moved off 5432 (PostgreSQL keeps it) |
| Redis | redis | 6379 | |
| MongoDB | mongo | 27017 | |
| Kafka | broker | 9092 | |
| Kafka-UI | web | 8080 | |
| schema-registry | web (Apicurio) | **8081** | moved off 8080 (Kafka-UI keeps it) |
| RabbitMQ | AMQP | 5672 | |
| RabbitMQ | management UI | 15672 | |
| ClickHouse | HTTP | 8123 | |
| ClickHouse | native TCP | **9004** | moved off 9000 (RustFS keeps it) |
| Neo4j | HTTP browser | 7474 | |
| Neo4j | Bolt | 7687 | |
| OpenSearch | HTTP | **9201** | moved off 9200 (Elasticsearch keeps it) |
| OpenSearch | transport | **9301** | reserved (not published in single-node) |
| Elastic-APM ES | HTTP | 9200 | |
| Elastic-APM ES | transport | 9300 | reserved (not published in single-node) |
| Elastic-APM Kibana | web | 5601 | |
| Elastic-APM APM | ingest | 8200 | |
| RustFS | S3 API | 9000 | |
| RustFS | console UI | 9001 | |
| ScyllaDB | CQL | 9042 | |
| ScyllaDB | monitoring | 9180 | reserved (optional; unique) |

## Utility index

| Utility | Server | Public reach (canonical port) | Purpose |
|---|---|---|---|
| [elastic-apm-stack](elastic-apm-stack/) | infra1 | Kibana `http://<infra1>:5601` · ES `:9200` · APM `:8200` | logs/traces/APM observability |
| [kafka](kafka/) | infra1 | UI `http://<infra1>:8080` · broker `<infra1>:9092` | event streaming (KRaft) |
| [schema-registry](schema-registry/) | infra1 | `http://<infra1>:8081/ui/` | Apicurio schema registry |
| [rabbitmq](rabbitmq/) | infra1 | UI `http://<infra1>:15672` · AMQP `:5672` | intra-context queues |
| [redis](redis/) | infra1 | `<infra1>:6379` (auth) | cache / KV |
| [postgresql](postgresql/) | infra2 | `<infra2>:5432` | relational — **one container, MANY databases** |
| [timescaledb](timescaledb/) | infra2 | `<infra2>:5433` | time-series Postgres |
| [mongodb](mongodb/) | infra2 | `<infra2>:27017` (auth) | document store |
| [opensearch](opensearch/) | infra2 | `http://<infra2>:9201` | search/analytics (security off — learning) |
| [clickhouse](clickhouse/) | infra2 | `http://<infra2>:8123/play` · native `:9004` | OLAP |
| [neo4j](neo4j/) | infra2 | Browser `http://<infra2>:7474` · Bolt `:7687` | graph |
| [rustfs](rustfs/) | infra2 | Console `http://<infra2>:9001/rustfs/console/index.html` · S3 `:9000` | S3 object storage |
| [scylladb](scylladb/) | infra2 | CQL `<infra2>:9042` | wide-column (capped 1 core / 350M) |

## How an `up` run works (per server)

1. **Preflight** — docker + compose reachable; **canonical-port check** across ALL utilities
   (live `.env` vs the map above — fails loudly on any divergence or duplicate); RAM guardrail
   (refuses a too-small host; `--force` / `UTIL_FORCE=1` overrides).
2. **PHASE 0 — pull ALL images first.** Every selected utility's images are pulled before any
   container starts (collapsed progress, `images ready (N/N)`); `--no-pull` skips.
3. **PHASE 1 — boot one utility at a time.** For each: 5 s cooldown (`UTIL_SLEEP`, 0 disables) →
   `setup_env.sh` (seeds chmod-600 `.env`, generates strong secrets, reuses them on re-run,
   auto-detects the box's public IP into `SERVER_IP`) → the utility's own `setup.sh up` →
   wait-healthy. One utility failing does NOT stop the fleet — it's reported per-tool.
4. **Summary + credentials** — per-server OK/FAILED/SKIP table with durations, then per-utility
   credential blocks with ready-to-paste endpoints. Endpoints use the machine's **PRIVATE
   (VPC) IP by default** — right for services and clients inside the same VPC, and no public
   address leaks into output. Need URLs that work from outside the VPC? Add
   `--public-host <public-ip>` (or `PUBLIC_HOST=<ip>`) to any command. Note kafka: the broker
   *advertises* `SERVER_IP`, so off-VPC kafka clients also need a re-`up` with the public IP.

## Knobs (env vars and flags)

| Knob | Default | Meaning |
|---|---|---|
| `INFRA1_HOST` / `INFRA2_HOST` | see host map | server IPs (edit when they change) |
| `SSH_KEY` / `--key` | `test.pem` | SSH private key |
| `UTIL_SLEEP` / `--sleep` | `5` | cooldown seconds before each boot (and between servers) |
| `UTIL_ONLY` / `--only` | — | run only tools whose name contains a token |
| `UTIL_SKIP` / `--skip` | — | skip tools whose name contains a token |
| `UTIL_MASK_SECRETS` / `--mask` | off | mask secrets in credential output |
| `UTIL_FORCE` / `--force` | off | override the RAM guardrail |
| `UTIL_NO_PULL` / `--no-pull` | off | skip PHASE 0 |
| `PUBLIC_HOST` / `--public-host` | auto | IP printed in credential endpoints |
| `NO_COLOR` / `--no-color` | auto | plain output (auto when not a TTY) |

## Layout of every utility

```text
<utility>/
├── README.md                      what it is, quick-start, how to connect & test
├── test.sh                        shared contract test (works against any variant)
├── .env.example                   shared defaults for test.sh
└── docker-single-node-setup/      ← the variant built in this pass
    ├── docker-compose.yml         SIMPLE + commented — readable on Docker day 1
    ├── .env.example               every variable explained; secrets left EMPTY
    ├── setup_env.sh               .env.example → .env + strong secrets (chmod 600)
    └── setup.sh                   up|down|purge|status|restart|logs + PUBLIC URL summary
```

Room is reserved in each utility for `native-single-node/`, `native-multi-node-cluster/`, and
`docker-multi-node-cluster/` later.

## The consolidation lesson (PostgreSQL)

Database-per-service = separate **databases** inside ONE server, never a server per service.
`postgresql/.env`'s `DKD_DATABASES=dkd_identity,dkd_catalog,dkd_custody` list drives an
idempotent provisioner — add a name, re-run `up`, get a new database + role + password.
**No new container, ever.**

## Conventions

- **Exact image pins + `stop_grace_period: 30s` + a real healthcheck on every container**
  (fleet rule — a floating `mongo:8` restart-looped silently; see BUILD-LOG).
- **Bind-mounted data** under `/data/dki/<utility>` — survives `docker compose down -v`;
  only `purge` deletes it.
- **Secrets** are auto-generated into `.env` (chmod 600, gitignored). `.env.example` never
  contains a real secret. Values with spaces (JVM opts) are double-quoted.
- **Memory caps everywhere**: `mem_limit` on every service plus engine budgets (JVM heaps,
  Scylla `--memory/--smp`, ClickHouse `MAX_SERVER_MEMORY_USAGE`, Redis `--maxmemory`).
- **test.sh** creates throwaway objects only, exercises real features (UTF-8 Bangla
  round-trips, expected-failure auth checks), deletes everything, proves zero residue.

Deferred to a later pass: kubernetes variants and the three non-docker-single variants.
