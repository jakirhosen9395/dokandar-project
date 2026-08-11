# Qdrant — utility dependency

Qdrant 1.18 is DOKANDAR's **vector database** — the ANN/embedding store behind the `16-recommendation`
service (vector recommendations, cross-sell, cold-start) and a consumer for `18-risk-trust`. This folder
holds the install variants plus a **shared test script** for all of them.

## Layout

```text
12_Qdrant/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (REST API, via curl) — works against ALL variants
├── 01_native_single/    ← native (no Docker), static binary + systemd, single node                  [TESTED]
├── 03_docker_single/    ← Docker Compose, single node, storage bind-mounted (survives down -v)       [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: 3 peers in one Raft consensus group                     [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-peer Raft cluster covers HA.)

> **Auth.** Qdrant's REST/gRPC API is protected by an **API key** (`QDRANT_API_KEY`, sent as the
> `api-key:` header). Each variant's `setup.sh` **auto-generates** a 24-char key when `.env`'s is empty
> (or `--gen-key`), accepts `--key KEY`, and saves it to that variant's `.env` (chmod 600). The built-in
> **/dashboard** (served on the HTTP port) is the browser UI — paste the key in its Settings. TLS is off
> (dev) — restrict at the firewall; the tests run over an SG-fenced VPC.

## The shared test script — `test.sh`

Uses **`curl`** against the REST API (api-key header). It confirms reachability + auth, creates a
throwaway **collection**, upserts bilingual-UTF-8 **points** with vectors, reads them back (count /
payload / **ANN search**), then **deletes the collection** and **proves zero residue**.

### How to run it

```bash
bash test.sh 01_native_single     # native (reads api-key + port from its .env)
# or against ANY Qdrant (e.g. cross-host) — pass host + key via env:
QDRANT_HOST=<host> QDRANT_API_KEY=<key> bash test.sh
```

Client auto-selects: **host** `curl` if on PATH, else a **`curlimages/curl`** Docker container
(`--network host`) — so a Docker variant tests with zero host packages.

### Reading the result

`RESULT: PASS — collection created, points upserted/searched/deleted, zero residue.` and exit `0` means
the REST API + api-key work and the vector index is clean. Any failure prints the failing checks.

## See also

- `../README.md` — the utility-dependency overview.
- `../../dependencies/03_Databases_datastores/08_Qdrant_1.18/` — the original install script + the
  `cluster_mode/run_book.md` native HA reference (3-peer Raft, `shard_number=3 replication_factor=2`).
