# ScyllaDB — utility dependency

ScyllaDB 2026.1 LTS is DOKANDAR's **wide-column store** — the write-heavy event stream behind the
`18-risk-trust` service. It is Cassandra-compatible (CQL on `:9042`). This folder holds the install
variants plus a **shared test script** for all of them.

## Layout

```text
14_ScyllaDB/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (CQL, via cqlsh) — works against ALL variants
├── 01_native_single/    ← native (no Docker), official apt repo + developer mode, single node          [TESTED]
├── 03_docker_single/    ← Docker Compose, single node, data bind-mounted (survives down -v)            [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: 3-node ring, replication_factor=3                         [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-node ring covers HA.)

> **Native on Ubuntu 26.04 "resolute".** ScyllaDB's apt repo is actually **codename-independent**
> (`debian-ubuntu/scylladb-<ver> stable main`), so it installs on resolute fine — the two real snags
> `01_native_single` handles are: the repo **signing key** must be the right id (`C503C686B007F39E`) and
> **exported** (apt's `signed-by` rejects a gpg keybox); and Scylla refuses to start with `rpc_address=0.0.0.0`
> unless **`broadcast_rpc_address`** is also set. It runs in **developer mode** (`--developer-mode 1`) to skip
> the invasive `scylla_setup` host tuning a shared box can't accept. (The deps layer marks the native *cluster*
> RECORD-ONLY because multiple nodes on shared boxes need the full host tuning + per-node `--smp`/`--memory`
> caps — the Docker ring here realises the tested HA path.)

> **Auth & UI.** ScyllaDB ships with the **authenticator OFF** (no username/password) — there are no
> credentials to generate. It is a CQL database with **no browser UI**; interact via **`cqlsh`** /
> **`nodetool`**. Tests run over an SG-fenced VPC.

## The shared test script — `test.sh`

Uses **`cqlsh`** (CQL). It confirms connectivity (`release_version`), creates a throwaway **keyspace +
table**, inserts bilingual-UTF-8 rows, reads them back (count / value via `SELECT JSON`), then **drops the
keyspace** and **proves zero residue** (`system_schema.keyspaces`).

### How to run it

```bash
bash test.sh 03_docker_single     # reads host/port from its .env
# or against ANY ScyllaDB (e.g. cross-host):
SCYLLA_HOST=<host> SCYLLA_CQL_PORT=9042 bash test.sh
```

Client auto-selects: **host** `cqlsh` if on PATH, else `cqlsh` inside a **`scylladb/scylla`** Docker
container (`--network host`) — so a Docker variant tests with zero host packages.

### Reading the result

`RESULT: PASS — keyspace created/written/read/dropped, zero residue.` and exit `0` means CQL works and the
schema is clean. Any failure prints the failing checks.

## See also

- `../README.md` — the utility-dependency overview.
- `../../dependencies/03_Databases_datastores/10_ScyllaDB_2026.1/` — the original install script + the
  `cluster_mode/run_book.md` (RECORD-ONLY on the shared native fleet; documents the `--smp`/`--memory` caps).
