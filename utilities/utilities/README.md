# DOKANDAR Utilities — Infrastructure Fleet

A ready‑to‑run pack of the **16 DOKANDAR infrastructure dependencies**, brought up by one‑shot
orchestrator scripts that install a chosen variant and then **print every credential** in one report.
**Two deployment models, same tools:**

- **One host** → **`setup.sh`** runs **both** bundles (all 16 tools) on a single machine, and
  **`setup.sh creds`** prints just the credentials + endpoints for everything.
- **Two hosts** → **`01_utility_setup.sh`** / **`02_utility_setup.sh`** split the fleet across two small
  servers (2 vCPU / 8 GB each), one bundle per box.

Built for a **low‑load development substrate** — you call each backing service only a handful of times a
day while building your application. It is **not** a production HA deployment (see
[Why this layout](#why-this-layout-sizing) and [Caveats](#caveats)).

---

## Table of contents

1. [What this is](#what-this-is)
2. [The unified `setup.sh` (one host)](#the-unified-setupsh-one-host)
3. [Why this layout (sizing)](#why-this-layout-sizing)
4. [Repository layout](#repository-layout)
5. [The two servers at a glance](#the-two-servers-at-a-glance)
6. [Quick start (copy‑paste)](#quick-start-copy-paste)
7. [The four install variants](#the-four-install-variants)
8. [The orchestrator scripts — full reference](#the-orchestrator-scripts--full-reference)
9. [Per‑tool reference (version / ports / UI / RAM)](#per-tool-reference)
10. [Working with a single tool](#working-with-a-single-tool)
11. [Credentials & `.env`](#credentials--env)
12. [Data persistence (`down` vs `purge`)](#data-persistence)
13. [Lifecycle command reference](#lifecycle-command-reference)
14. [Host prerequisites](#host-prerequisites)
15. [Port map & conflict policy](#port-map--conflict-policy)
16. [Caveats](#caveats)
17. [Committing your changes](#committing-your-changes)

---

## What this is

Each of the 16 tools ships **three working install variants** plus a shared contract test:

| File / dir | What it is |
|---|---|
| `setup.sh` | **Unified one‑host orchestrator** — runs **both** bundles (all 16 tools); adds a `creds` action |
| `01_utility_setup.sh` | Orchestrator for **Server A** (`utility1`, 6 tools) |
| `02_utility_setup.sh` | Orchestrator for **Server B** (`utility2`, 10 tools) |
| `utility1/<NN_Tool>/` | A Server‑A tool, with its variants + `README.md` + `test.sh` |
| `utility2/<NN_Tool>/` | A Server‑B tool, with its variants + `README.md` + `test.sh` |

Per tool you get: `01_native_single/`, `02_native_cluster/` *(unbuilt slot)*, `03_docker_single/`,
`04_docker_cluster/`, a tool‑level `README.md`, and a tool‑level `test.sh`. Each variant has its own
idempotent `setup.sh` that **auto‑generates a complex password/token/key** (the `.env.example` ships
them empty) and prints the connection details once. The orchestrators just drive every tool's `setup.sh`
in order and re‑collect the secrets into one consolidated report at the end.

---

## The unified `setup.sh` (one host)

Running everything on **one machine**? `setup.sh` is the single entry point — it merges every tool from
`utility1/` **and** `utility2/`, sorts them `01…16`, and drives the whole fleet in one chosen variant.
It shares all the behaviour of the per‑bundle scripts (default skip, RAM guardrail, cooldown, quiet pulls,
port preflight) but its **port preflight checks across *both* bundles**, so co‑location clashes are caught
before Docker is touched.

```bash
bash setup.sh                      # bring the whole fleet up (Docker single‑node)  ← default
bash setup.sh 03_docker_single     # same, explicit variant
bash setup.sh creds                # print ONLY credentials + endpoints for every tool
bash setup.sh status               # status of every tool
bash setup.sh down                  # stop everything (DATA PRESERVED)
bash setup.sh purge                 # stop + DELETE data
```

* **Argument order is flexible:** `setup.sh <variant> <action>` **or** `setup.sh <action>` (variant then
  defaults to `03_docker_single`). So `setup.sh creds`, `setup.sh status`, and `setup.sh 04_docker_cluster`
  all do the obvious thing.
* Same env knobs as the per‑bundle scripts — `UTIL_SKIP` (default `"prometheus openbao"`), `UTIL_ONLY`,
  `UTIL_SLEEP` (default 15s), `UTIL_FORCE`, `UTIL_MASK_SECRETS`, `NO_COLOR` — plus `UTIL_ROOT=/path` to
  point at the bundles in a non‑default location.

### `setup.sh creds` — credentials, nothing else

`creds` reads each tool's saved `.env` and prints **only** the connection essentials — endpoints/URLs,
`host:port`, user, password/token/secret/keys, UI links — with **no** image, version, heap, or data‑path
noise. It works even while containers are down (it reads the saved secrets), and `UTIL_MASK_SECRETS=1`
masks the values. Example:

```
### 01_PostgreSQL
   endpoint       postgresql://postgres:••••@HOST:5432/postgres
   host:port      HOST:5432
   user           postgres
   password       s3cr3t…
### 10_RustFS
   s3-endpoint    http://HOST:9002
   console-ui     http://HOST:9001
   access-key     AKIA…
   secret-key     ……
```

> ⚠️ **The full fleet in single‑node mode is ~10 GB idle — it will not fit one 8 GB box.** On a single
> `m7i-flex.large` either skip more tools (`UTIL_SKIP="prometheus openbao neo4j elasticsearch …"`) or use a
> ≥ 16 GB instance. For 2 vCPU / 8 GB, the **two‑box split** (below) is the comfortable layout.

---

## Why this layout (sizing)

All 16 tools in **cluster mode** need **~21 GB RAM** — that does not fit two 8 GB boxes (and most stacks
are single‑host‑only anyway). In **single‑node mode** the whole fleet is **~10 GB idle**, which splits
cleanly across two 8 GB servers at **~5.1 GB each** — comfortable, with headroom for your application:

| | Server A (`utility1`) | Server B (`utility2`) |
|---|---|---|
| Tools | 6 | 10 |
| Idle RAM (single mode) | ~5.1 GB | ~5.1 GB |
| CPU at ~5–10 req/day | well under 2 vCPU | well under 2 vCPU |

> At this load, **cluster mode buys you nothing** (no traffic to scale, no uptime SLA to protect) while
> costing ~2× the RAM. Use `03_docker_single`.

---

## Repository layout

```
utilities/
├── setup.sh                   → UNIFIED one-host orchestrator (utility1 + utility2) + `creds`
├── 01_utility_setup.sh        → drives Server A (utility1)
├── 02_utility_setup.sh        → drives Server B (utility2)
├── README.md                  → this file
├── utility1/                  ← SERVER A  (6 tools)
│   ├── 01_PostgreSQL/
│   │   ├── 01_native_single/   (apt + systemd, no Docker) → setup.sh + .env.example
│   │   ├── 02_native_cluster/  (UNBUILT slot — no setup.sh, auto‑skipped)
│   │   ├── 03_docker_single/   (one Compose container)    → setup.sh + .env.example + docker-compose.yml
│   │   ├── 04_docker_cluster/  (Compose HA, multi‑node)   → setup.sh + .env.example + docker-compose.yml
│   │   ├── README.md
│   │   └── test.sh             (write→read→delete contract test)
│   ├── 04_Redis/   07_Elastic_APM/   08_Prometheus/   11_ClickHouse/   14_ScyllaDB/
└── utility2/                  ← SERVER B  (10 tools)
    ├── 02_MongoDB/  03_Elasticsearch/  05_Kafka/  06_RabbitMQ/  09_OpenBao/
    └── 10_RustFS/   12_Qdrant/  13_Neo4j/  15_NATS/  16_Temporal/
```

---

## The two servers at a glance

| Server | Script | Tools |
|---|---|---|
| **A** (`utility1`) | `01_utility_setup.sh` | PostgreSQL · Redis · Elastic APM · Prometheus · ClickHouse · ScyllaDB |
| **B** (`utility2`) | `02_utility_setup.sh` | MongoDB · Elasticsearch · Kafka · RabbitMQ · **OpenBao** · RustFS · Qdrant · Neo4j · NATS · Temporal |

> **OpenBao lives on Server B.** Its default port `8200` collided with **Elastic APM** (also `8200`) on
> Server A, so — per the "move the tool to the other server" policy — it was relocated to B, where `8200`
> is free. See [Port map & conflict policy](#port-map--conflict-policy).

### Default tool filter & load balance

To keep both 2 vCPU / 8 GB boxes (e.g. **`m7i-flex.large`**) comfortable, the orchestrators **skip two
tools by default** — **Prometheus** (monitoring) on Server A and **OpenBao** (secrets) on Server B —
via `UTIL_SKIP="prometheus openbao"`. **Elastic APM is kept** (it's the app's tracing backend). Only the
*tools* are filtered; every lifecycle command (`up`/`down`/`purge`/`status`) still runs on the rest.

With that default, the **running** footprint is RAM-balanced — neither box is overwhelmed:

| | Server A (`utility1`) | Server B (`utility2`) |
|---|---|---|
| Running tools | 5 — PostgreSQL · Redis · **Elastic APM** · ClickHouse · ScyllaDB | 9 — MongoDB · Elasticsearch · Kafka · RabbitMQ · RustFS · Qdrant · Neo4j · NATS · Temporal |
| Skipped (default) | Prometheus | OpenBao |
| Idle RAM (single mode) | **~5.0 GB** | **~4.9 GB** |
| Headroom on 8 GB | ~3 GB for OS + your app | ~3 GB for OS + your app |

> Server A runs **fewer tools but heavier ones** — Elastic APM alone is ~2.7 GB — so RAM (the real
> constraint on an 8 GB box), not tool count, is what's balanced. Run the **full** fleet with `UTIL_SKIP=""`,
> or change what's skipped, e.g. `UTIL_SKIP="prometheus openbao neo4j"`.

---

## Quick start (copy‑paste)

Run these **on each server** (both servers clone the same repo; each just runs *its own* orchestrator —
Server A runs `01_…`, Server B runs `02_…`).

### Step 1 — install Docker (once per server)

```bash
curl -fsSL https://get.docker.com -o get-docker.sh
sudo sh get-docker.sh

sudo groupadd docker
sudo usermod -aG docker $USER
newgrp docker

sudo systemctl enable docker.service
sudo systemctl enable containerd.service
```

> `groupadd docker` may say *"group already exists"* — the Docker install script usually created it; that
> warning is harmless. `newgrp docker` activates the group in your current shell so `docker` works without
> `sudo` (a fresh login does the same).

### Step 2 — clone this repo and enter it

```bash
git clone https://gitlab.com/learningdevopstools/utilities/utilities.git
cd utilities
```

### Step 3 — bring the fleet up (single‑node Docker — recommended)

```bash
# --- One host (all 16 tools) ---
bash setup.sh                       # = bash setup.sh 03_docker_single up

# --- Two hosts (one bundle each) ---
bash 01_utility_setup.sh 03_docker_single    # on Server A
bash 02_utility_setup.sh 03_docker_single    # on Server B
```

Each run seeds every tool's `.env`, runs a **port‑uniqueness preflight**, starts each tool, prints a
**result table**, and ends with a **CREDENTIALS** block listing every generated password/token/key.

### Step 4 — check status / re‑print credentials any time

```bash
bash setup.sh status                # one host: status of everything
bash setup.sh creds                 # one host: credentials + endpoints only (no noise)

bash 01_utility_setup.sh 03_docker_single status    # two hosts: Server A
bash 02_utility_setup.sh 03_docker_single status    # two hosts: Server B
```

### Step 5 — tear down

```bash
bash 01_utility_setup.sh 03_docker_single down       # stop, KEEP data
bash 01_utility_setup.sh 03_docker_single purge      # stop, DELETE data
```

### Other install variants (native & cluster)

The orchestrators accept **all four** variants as the first argument — same script, just swap the word.

```bash
# --- 01_native_single — apt/binary + systemd, NO Docker (the script runs each tool's setup via sudo) ---
bash 01_utility_setup.sh 01_native_single            # Server A, native install (will prompt for sudo)
bash 02_utility_setup.sh 01_native_single            # Server B, native install
bash 01_utility_setup.sh 01_native_single status     # status
bash 01_utility_setup.sh 01_native_single down        # 'down' → native 'uninstall' (data kept)

# --- 04_docker_cluster — Docker Compose HA, 3–6 nodes PER TOOL ---
# Each tool's setup.sh auto-sets its own host vars (Kafka advertised host, Redis announce IP) and
# sysctls (ScyllaDB fs.aio-max-nr, Elasticsearch vm.max_map_count) — no manual prep needed.
bash 02_utility_setup.sh 04_docker_cluster           # bring the whole bundle up in cluster mode
bash 02_utility_setup.sh 04_docker_cluster purge      # stop + delete data
```

> ⚠️ **Cluster mode does not fit the full fleet on 8 GB** (~21 GB needed) and each stack is single‑host‑only
> by design. Use it to exercise **one** tool's cluster topology on a bigger box, e.g.:
> ```bash
> cd utility2/05_Kafka/04_docker_cluster && bash setup.sh up
> ```

---

## The four install variants

Pass the variant as the **first argument**. The same word maps to the right per‑tool `setup.sh` verb.

| Variant arg | What it installs | Footprint | Orchestrator verb (up) |
|---|---|---|---|
| `01_native_single` | apt/binary + **systemd**, no Docker. Data under `/data/<tool>`. **Needs `sudo`.** | lightest | `install` |
| `02_native_cluster` | **Unbuilt slot** — no `setup.sh`. Always **SKIPPED**. | — | *(skipped)* |
| `03_docker_single` | One Docker Compose container; data on a **host bind mount** that survives `down -v`. **Recommended.** | low | `up` |
| `04_docker_cluster` | Docker Compose **HA** (3–6 nodes per tool). **Won't fit 8 GB for the whole fleet.** | heavy | `up` |

> For this 2×(2 vCPU / 8 GB) plan use **`03_docker_single`**.

---

## The orchestrator scripts — full reference

```
bash 0N_utility_setup.sh <variant> [action]
```

* `<variant>` *(required)* — `01_native_single` | `02_native_cluster` | `03_docker_single` | `04_docker_cluster`
* `[action]` *(optional, default `up`)* — `up` | `down` | `purge` | `status`

### Environment variables

| Variable | Effect |
|---|---|
| `UTIL_SKIP="a b"` | Skip tools whose name contains any token (substring, case-insensitive — `prometheus`, `08`, `08_Prometheus` all match). **Default `"prometheus openbao"`.** Set `UTIL_SKIP=""` to run the full fleet. |
| `UTIL_ONLY="a b"` | Run **only** tools matching a token (takes precedence over `UTIL_SKIP`). E.g. `UTIL_ONLY=postgres`. |
| `UTIL_SLEEP=N` | Seconds to pause **between** tool bring-ups (default **15**) so a small box isn't hit by many simultaneous container/JVM starts. `0` disables. Bring-up only. |
| `UTIL_FORCE=1` | Proceed with `04_docker_cluster` even when the host has < 16 GB RAM (normally refused — see the RAM guardrail below). |
| `UTIL_MASK_SECRETS=1` | Mask secret values in the CONSOLIDATED CREDENTIALS block (read them from each tool's `.env` instead). |
| `UTIL_BUNDLE=/path` | Use a tool bundle in a non-default location. |
| `NO_COLOR=1` | Disable ANSI colour (also auto-disabled when stdout is not a TTY). |

Each run also prints the **host's CPU / RAM / swap** in its header and shows the active **tool filter**
(`skip = …` and the list of excluded tools), so what will and won't come up is visible up front.

### What a run does, in order

1. **Validates** the variant/action arguments.
2. **Locates the bundle** — `$UTIL_BUNDLE` if set, else `./utility1` (or `./utility2`) next to the script,
   else the script's own directory. Tools are auto‑discovered by globbing numbered folders, so adding or
   removing a tool needs no script edit.
3. **Runtime preflight** —
   * Docker variants: checks `docker`, the `docker compose` plugin, and daemon reachability (falls back to
     `sudo` for Docker if your user isn't in the `docker` group yet).
   * Native variants: ensures `sudo` is available (native installers touch apt/systemd).
   * **`04_docker_cluster` RAM guardrail** *(bring‑up only)*: the full fleet needs ~21 GB in cluster mode;
     on a host with < 16 GB RAM it **refuses to start** (use `03_docker_single`, or `UTIL_FORCE=1` to override).
4. **Port‑uniqueness preflight** *(bring‑up only)* — scans every tool's `*_PORT` and **aborts with a clear
   message** if two tools would publish the same host port, before touching Docker. Tools excluded by the
   filter (below) are ignored here, so a skipped tool never causes a false collision.
5. **Per tool**, in numeric order:
   * skips tools excluded by `UTIL_SKIP` / `UTIL_ONLY` (records `SKIP (UTIL_SKIP)`); by default
     Prometheus and OpenBao are skipped;
   * skips `02_native_cluster` and any variant with no `setup.sh` (records `SKIP`);
   * seeds `.env` from `.env.example` if missing (creds auto‑generate on first run);
   * runs that tool's `setup.sh <verb>`; records `OK` or `FAILED` — **one failure does not abort the rest**.
6. **Result table** — `OK` / `FAILED` / `SKIP` per tool.
7. **Consolidated credentials** *(bring‑up only)* — reads each succeeded tool's `.env` and prints the
   secrets in one block.
8. **Exit code** — non‑zero if any tool failed.

### Examples

```bash
bash 01_utility_setup.sh 03_docker_single            # Server A: bring up (Docker single)  ← recommended
bash 02_utility_setup.sh 03_docker_single            # Server B: bring up
bash 01_utility_setup.sh 01_native_single            # Server A: native packages, no Docker (uses sudo)
bash 02_utility_setup.sh 04_docker_cluster           # Server B: HA cluster per tool (heavy — see caveat)
bash 02_utility_setup.sh 03_docker_single status     # Server B: status of each tool
bash 01_utility_setup.sh 03_docker_single down        # Server A: stop (data kept)
bash 02_utility_setup.sh 03_docker_single purge       # Server B: stop + delete data

# Point at a bundle in a non‑default location:
UTIL_BUNDLE=/opt/dokandar/utility1 bash 01_utility_setup.sh 03_docker_single
```

---

## Per‑tool reference

Versions, host ports, and browser UIs are taken from each tool's `03_docker_single` files. `host` = the
server's IP/DNS. Idle RAM is approximate single‑node resident memory at ~5–10 requests/day.

### Server A — `utility1` (`01_utility_setup.sh`)

| Tool | Version | Host port(s) | Browser UI | Idle RAM |
|---|---|---|---|---|
| `01_PostgreSQL` | PostgreSQL 18 | `5432` wire | none | ~160 MB |
| `04_Redis` | Redis 8 | `6379` | none | ~70 MB |
| `07_Elastic_APM` | Elastic APM 9.4.2 (ES + Kibana + apm‑server) | `9200` ES · `8200` APM ingest · `5601` Kibana | `http://host:5601` (Kibana) | ~2.7 GB |
| `08_Prometheus` | Prometheus 3.12.0 | `9090` HTTP+UI | `http://host:9090` (built‑in) | ~130 MB |
| `11_ClickHouse` | ClickHouse 26.3 LTS | `8123` HTTP · `9000` native TCP | `http://host:8123/play` | ~750 MB |
| `14_ScyllaDB` | ScyllaDB 2026.1 | `9042` CQL | none (`cqlsh` / `nodetool`) | ~1.3 GB |

### Server B — `utility2` (`02_utility_setup.sh`)

| Tool | Version | Host port(s) | Browser UI | Idle RAM |
|---|---|---|---|---|
| `02_MongoDB` | MongoDB 7.0 | `27017` | none | ~300 MB |
| `03_Elasticsearch` | Elasticsearch 9.4.2 | `9201` HTTP | none (Kibana is the APM stack on Server A) | ~1.2 GB |
| `05_Kafka` | Apache Kafka 4.3.0 (KRaft) | `9092` bootstrap · `8080` kafka‑ui | `http://host:8080` (kafka‑ui) | ~1.15 GB |
| `06_RabbitMQ` | RabbitMQ 4.x (`4-management`) | `5672` AMQP · `15672` mgmt | `http://host:15672` | ~210 MB |
| `09_OpenBao` | OpenBao 2.5.4 | `8200` API+UI | `http://host:8200/ui` | ~120 MB |
| `10_RustFS` | RustFS 1.0.0‑beta.8 | `9002` S3 API · `9001` console | `http://host:9001` | ~180 MB |
| `12_Qdrant` | Qdrant 1.18.2 | `6333` REST · `6334` gRPC | `http://host:6333/dashboard` | ~200 MB |
| `13_Neo4j` | Neo4j 2026.05.0 (Community) | `7474` HTTP/Browser · `7687` Bolt | `http://host:7474` (Neo4j Browser) | ~1.25 GB |
| `15_NATS` | NATS 2.14 (JetStream) | `4222` client · `8222` monitoring | none (`:8222` is JSON monitoring) | ~100 MB |
| `16_Temporal` | Temporal dev‑server | `7233` gRPC · `8233` Web UI | `http://host:8233` | ~350 MB |

---

## Working with a single tool

You don't have to use the orchestrators — each tool is self‑contained. Run its `setup.sh` from the variant
folder, and its `test.sh` from the tool folder.

```bash
# --- Bring ONE tool up (Docker single) ---
cd utility1/01_PostgreSQL/03_docker_single
cp .env.example .env            # only needed the first time; the orchestrator seeds it for you
bash setup.sh up                # auto‑generates the password, prints connection details

# --- Run that tool's contract test (write → read → delete, proves zero residue) ---
cd ..                           # back to utility1/01_PostgreSQL
bash test.sh 03_docker_single   # the arg selects which variant's .env to read

# --- Inspect / tail / tear down ---
cd 03_docker_single
bash setup.sh status
bash setup.sh logs
bash setup.sh down              # stop, keep data
bash setup.sh purge             # stop + delete data

# --- Native variant (no Docker) needs sudo ---
cd utility2/09_OpenBao/01_native_single
sudo bash setup.sh install
sudo bash setup.sh status
sudo bash setup.sh uninstall    # keep data
sudo bash setup.sh purge        # delete data
```

**Test the whole fleet after a bring‑up** (optional — loops each tool's `test.sh`):

```bash
# On Server A, from the utilities/ dir:
for t in utility1/*/; do echo "== $(basename "$t") =="; ( cd "$t" && bash test.sh 03_docker_single ); done
```

---

## Credentials & `.env`

* Every `.env.example` ships secrets **empty**; the tool's `setup.sh` **auto‑generates** a complex
  password/token/key on the first `up`/`install` and **writes it back** to that variant's `.env`.
* `.env` files are **`chmod 600`** and **git‑ignored** — only `.env.example` is committed.
* Secrets are shown **once** per tool during bring‑up, and again in the orchestrator's
  **CONSOLIDATED CREDENTIALS** block.

**Which `.env` keys hold the generated secret(s):**

| Tool | Secret key(s) in `.env` |
|---|---|
| PostgreSQL | `POSTGRES_PASSWORD` |
| Redis | `REDIS_PASSWORD` |
| Elastic APM | `ELASTIC_PASSWORD`, `KIBANA_PASSWORD`, `KIBANA_ENCRYPTION_KEY`, `APM_SECRET_TOKEN` |
| Prometheus | *(none — no auth in dev)* |
| ClickHouse | `CLICKHOUSE_PASSWORD` |
| ScyllaDB | *(none — no auth in dev)* |
| MongoDB | `MONGO_ROOT_PASSWORD` |
| Elasticsearch | `ELASTIC_PASSWORD` |
| Kafka | *(PLAINTEXT in dev; `KAFKA_CLUSTER_ID` is generated, not a secret)* |
| RabbitMQ | `RABBITMQ_DEFAULT_PASS` |
| OpenBao | `BAO_ROOT_TOKEN`, `BAO_UNSEAL_KEY` |
| RustFS | `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY` |
| Qdrant | `QDRANT_API_KEY` |
| Neo4j | `NEO4J_PASSWORD` |
| NATS | `NATS_AUTH_TOKEN` |
| Temporal | *(none — no auth in dev)* |

```bash
# Re‑read one tool's secrets later:
cat utility2/09_OpenBao/03_docker_single/.env          # OpenBao root token + unseal key
bash utility1/11_ClickHouse/03_docker_single/setup.sh status

# Re‑print the whole consolidated credentials block:
bash 01_utility_setup.sh 03_docker_single status
```

---

## Data persistence

* Data lives on **host bind mounts** under `DATA_ROOT` (default `/data/<tool>...`). For Docker variants it
  **survives `docker compose down -v`** — only `purge` deletes it.
* `down` / `uninstall` → stop the service, **keep** data.
* `purge` → stop **and delete** the data directory (irreversible).

```bash
DATA_ROOT=/srv/data bash 01_utility_setup.sh 03_docker_single   # override where data lands
```

---

## Lifecycle command reference

| Goal | Docker variant verb | Native variant verb | Via orchestrator (`action`) |
|---|---|---|---|
| Start / install | `up` | `install` | `up` *(default)* |
| Stop, keep data | `down` | `uninstall` | `down` |
| Stop, delete data | `purge` | `purge` | `purge` |
| Health / status | `status` | `status` | `status` |
| **Credentials only** | — | — | **`creds`** *(`setup.sh` only)* |
| Tail logs | `logs` | — | *(per‑tool only)* |

The orchestrator translates the `action` you pass into the correct per‑tool verb automatically
(`up`→`install` for native, etc.). **`creds`** is unique to the unified `setup.sh`: it prints a clean,
credentials‑only report (endpoints, host:port, user, password/token/keys) for every tool — no image,
version, or data‑path lines. `UTIL_MASK_SECRETS=1` masks the values.

---

## Host prerequisites

* **Docker variants:** Docker Engine + the `docker compose` plugin — install with the official script (see
  [Quick start Step 1](#quick-start-copy-paste)):
  ```bash
  curl -fsSL https://get.docker.com -o get-docker.sh && sudo sh get-docker.sh
  sudo usermod -aG docker $USER && newgrp docker        # run docker without sudo
  ```
* **Native variants:** `sudo` (they install apt packages and systemd units on the host — no Docker needed).
* **Kernel `sysctl` (host‑global, set by the tools' `setup.sh`, listed here for awareness):**
  * **Elasticsearch** (Server B) and **Elastic APM** (Server A) need `vm.max_map_count=262144`.
    ```bash
    sudo sysctl -w vm.max_map_count=262144
    echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-dokandar.conf   # persist
    ```
  * **ScyllaDB** single‑node runs in developer mode (no host tuning). Its `04_docker_cluster` needs
    `fs.aio-max-nr=1048576` (handled automatically by that variant's `setup.sh`).

---

## Port map & conflict policy

**Policy:** if two tools on the same server want the same host port, **move one tool to the other server**
(preferred), or change its `*_PORT` in `.env`. The orchestrator enforces this with a preflight that aborts
on any duplicate host port before starting anything.

The only collision in the default split was **OpenBao `8200` vs Elastic APM `8200`** on Server A —
resolved by **moving OpenBao to Server B** (where `8200` is free), keeping its default port. After the move,
both bundles are conflict‑free (**Server A = 9 unique host ports, Server B = 17**). If you later add a tool
and hit a clash, the preflight prints exactly which two tools and which port:

```
✗ host-port collision(s) — these tools cannot share one machine until you edit the offending .env
  (per policy: move one of the clashing tools to the OTHER server, or change its *_PORT):
   port 8200    used by:  07_Elastic_APM(APM_PORT)  09_OpenBao(BAO_API_PORT)
```

### Running BOTH bundles on ONE host

The preflight only checks **within one bundle**, so if you run `utility1` **and** `utility2` on the *same*
machine, Docker (not the preflight) rejects the cross-bundle clashes at bind time. With the default skip,
two tools overlap Server A's stack — they ship **pre-resolved** so co-location works out of the box:

| utility2 tool | host port | why | clashed with (utility1) |
|---|---|---|---|
| `03_Elasticsearch` | **9201** (was 9200) | second Elasticsearch on the box | Elastic APM's ES `9200` |
| `10_RustFS` | **9002** (was 9000) | S3 API | ClickHouse native TCP `9000` |

> ⚠️ **RAM:** both full bundles on one box is **~10 GB** — it will **not** fit a single 8 GB
> `m7i-flex.large` (the cooldown only smooths the *startup* spike; steady-state still busts the box). For
> two 8 GB boxes keep one bundle each (no clash, ~5 GB each). To run the **full** fleet co-located without
> the default skip you must also resolve OpenBao `8200`↔APM and Prometheus `9092`↔Kafka.

---

## Caveats

* **`02_native_cluster` is an unbuilt slot** (no `setup.sh`) — every tool is SKIPPED for that variant.
* **`04_docker_cluster` will not fit 8 GB for the full fleet** (~21 GB) and each stack is single‑host‑only
  by design (host networking / fixed ports / one advertised host). Use it to exercise **one** tool's cluster
  topology, not to run the dev substrate. The orchestrator now **refuses** a cluster bring‑up on a host with
  < 16 GB RAM (override with `UTIL_FORCE=1`) — this is what OOM‑locks an 8 GB box.
* These are **co‑located dev topologies**, not fault‑isolated HA — a 3‑node quorum needs 3 separate hosts.
* **MongoDB** is pinned to `7.0` (the `8.x` line crash‑loops on Linux kernel ≥ 6.19).

---

## Committing your changes

This directory is a git repo; nothing here auto‑commits. When you're happy:

```bash
git add -A
git commit -m "Bring up DOKANDAR utilities fleet"
git push        # if a remote is configured
```

`.env` files stay out of git (git‑ignored); only `.env.example` templates are tracked.
