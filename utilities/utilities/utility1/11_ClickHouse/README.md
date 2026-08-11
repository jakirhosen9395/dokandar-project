# ClickHouse — utility dependency

ClickHouse 26.3 LTS is DOKANDAR's **OLAP / analytics** column store — the reporting warehouse behind the
`11-reporting` service (fact projection from Kafka, NBR VAT / DBID exports), alongside PostgreSQL. This
folder holds the install variants plus a **shared test script** for all of them.

## Layout

```text
11_ClickHouse/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (HTTP interface, via curl) — works against ALL variants
├── 01_native_single/    ← native (no Docker), apt repo + systemd, single node                       [TESTED]
├── 03_docker_single/    ← Docker Compose, single node, data bind-mounted (survives down -v)          [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: 1 shard x 3 replicas + embedded 3-node Keeper           [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-replica cluster covers HA.)

> **Auth.** ClickHouse's SQL user is `default` (`CLICKHOUSE_USER`). Each variant's `setup.sh`
> **auto-generates** a 24-char password when `.env`'s is empty (or `--gen-password`), accepts
> `--user U` / `--password P`, and saves them to that variant's `.env` (chmod 600). The built-in
> **/play SQL console** (the HTTP interface) is the browser UI. TLS is off (dev) — restrict at the
> firewall; the tests run over an SG-fenced VPC.

## The shared test script — `test.sh`

Uses **`curl`** against the HTTP interface (basic auth). It confirms connectivity (`SELECT 1`), creates a
throwaway **database + MergeTree table**, inserts bilingual-UTF-8 rows, reads them back (count / value /
aggregate), then **drops the database** and **proves zero residue** (`system.databases`).

### How to run it

```bash
bash test.sh 01_native_single     # native (reads user/password + port from its .env)
# or against ANY ClickHouse (e.g. cross-host) — pass host + creds via env:
CLICKHOUSE_HOST=<host> CLICKHOUSE_USER=default CLICKHOUSE_PASSWORD=<pw> bash test.sh
```

Client auto-selects: **host** `curl` if on PATH, else a **`curlimages/curl`** Docker container
(`--network host`) — so a Docker variant tests with zero host packages.

### Reading the result

`RESULT: PASS — table created/written/read/dropped, zero residue.` and exit `0` means the HTTP interface +
credentials work and the schema is clean. Any failure prints the failing checks.

## See also

- `../README.md` — the utility-dependency overview.
- `../../dependencies/03_Databases_datastores/07_ClickHouse_26.3_LTS/` — the original install script + the
  `cluster_mode/run_book.md` native HA reference (1 shard × 3 replicas + embedded Keeper, ReplicatedMergeTree).
