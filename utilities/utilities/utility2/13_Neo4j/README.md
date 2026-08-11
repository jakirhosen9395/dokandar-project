# Neo4j — utility dependency

Neo4j 2026.x is DOKANDAR's **graph database** — the route/optimization graph behind the `17-shipping`
service (multi-courier orchestration, rural agent routing) and a fraud subgraph for `18-risk-trust`. This
folder holds the install variants plus a **shared test script** for all of them.

## Layout

```text
13_Neo4j/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (HTTP Cypher API, via curl) — works against ALL variants
├── 01_native_single/    ← native (no Docker), Community via apt + systemd, single node              [TESTED]
├── 03_docker_single/    ← Docker Compose, Community, data bind-mounted (survives down -v)            [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: 3 PRIMARY servers (Enterprise EVAL, autonomous cluster) [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-primary cluster covers HA.)

> **Editions.** Neo4j **Community** (GPLv3) is **single-node by design** — its `dbms.cluster.*` keys are
> no-ops. Causal / autonomous **clustering is Enterprise-only**. So `01_native_single` + `03_docker_single`
> run **Community**, while `04_docker_cluster` runs **Enterprise under the EVALUATION licence**
> (`NEO4J_ACCEPT_LICENSE_AGREEMENT=eval`) — **a deliberate choice to make the HA cluster testable; eval is
> dev/test only, NOT a production licence.**

> **Auth.** The `neo4j` user's password (`NEO4J_PASSWORD`, ≥ 8 chars) is **auto-generated** (24-char) by
> each variant's `setup.sh` when `.env`'s is empty (or `--gen-password`); `--password P` fixes it. Native
> uses `neo4j-admin dbms set-initial-password`; the Docker variants use `NEO4J_AUTH`. Saved to that
> variant's `.env` (chmod 600). The built-in **Neo4j Browser** (HTTP port) is the web UI.

## The shared test script — `test.sh`

Uses **`curl`** against the HTTP Cypher transaction endpoint (`/db/neo4j/tx/commit`, basic auth). It
confirms connectivity (`RETURN 1`), creates a throwaway **labelled subgraph** (nodes + a relationship,
bilingual-UTF-8 properties), reads it back (count / value / relationship), then **DETACH DELETEs** that
label and **proves zero residue**. Its label is unique per run, so it never touches other data. Cluster
note: writes are **server-side routed** to the leader, so the test works against any node.

### How to run it

```bash
bash test.sh 01_native_single     # native (reads user/password + port from its .env)
# or against ANY Neo4j (e.g. cross-host) — pass host + creds via env:
NEO4J_HOST=<host> NEO4J_USER=neo4j NEO4J_PASSWORD=<pw> bash test.sh
```

Client auto-selects: **host** `curl` if on PATH, else a **`curlimages/curl`** Docker container.

### Reading the result

`RESULT: PASS — subgraph created/queried/deleted, zero residue.` and exit `0` means the HTTP API + creds
work and the graph is clean. Any failure prints the failing checks.

## See also

- `../README.md` — the utility-dependency overview.
- `../../dependencies/03_Databases_datastores/09_Neo4j_2026.x/` — the original Community install script + the
  `cluster_mode/run_book.md` (RECORD-ONLY on Community; documents the Enterprise procedure this cluster realises).
