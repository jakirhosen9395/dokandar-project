# Elasticsearch 9.4 — utility dependency

Elasticsearch is DOKANDAR's search + analytics engine: the `05-search` / `08-review` services' index, and
the platform-wide application-log sink (`logs-app-<service>-*`). This folder holds the install variants
plus a **shared test script** that works against all of them.

## Layout

```text
03_Elasticsearch/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (curl-based) — works against ALL variants
├── 01_native_single/    ← native (no Docker), systemd, env-file, data in /data/elasticsearch     [TESTED]
├── 03_docker_single/    ← Docker Compose, bind-mounted data (survives `down -v`)                  [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA, 3 nodes es01/es02/es03 (transport TLS)               [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-node cluster covers HA.)

**Security is ON** in every variant (the built-in `elastic` superuser; auto-generated complex password,
saved to that variant's `.env`, chmod 600). The HTTP layer uses **plain HTTP basic auth** (no TLS-cert
hassle for clients); the multi-node cluster additionally secures **inter-node transport with a shared
PKCS12 cert** (mandatory for multi-node security — the keyFile-equivalent). `setup.sh` prints a
credentials summary at the end; a no-flag re-run reuses the password, `--gen-password` rotates it.

Two host prerequisites Elasticsearch needs (the variants set them): **`vm.max_map_count=262144`** (a host
sysctl — needed by native AND docker since docker shares the kernel) and a **small JVM heap** (`512m` per
node by default — a 3-node cluster is 3 JVMs on one box).

## The shared test script — `test.sh`

Uses **`curl`** (universal — no client to install), so the same script tests any variant. It:

1. confirms connectivity **and authentication** (`_cluster/health`);
2. creates a throwaway `dokandar_estest_<ts>` index with an explicit mapping;
3. bulk-indexes bilingual UTF-8 docs, then exercises count, a term search, a `sum` aggregation, an update;
4. **deletes the index** (trap-guarded) and **proves zero residue**;
5. writes the summary to `test-result.txt` and exits non-zero on any failure.

### How to run it

```bash
bash test.sh 01_native_single     # native (reads its .env)
bash test.sh 03_docker_single     # docker single-node
bash test.sh 04_docker_cluster    # docker HA cluster (connects to a node)
# or ANY server, e.g. cross-host:
bash test.sh "http://elastic:<password>@<host>:9200"
ES_URL='http://elastic:<password>@host:9200' bash test.sh
```

### Run modes

`curl` on `PATH` → **host mode**. No curl but Docker present → **docker mode** (`curlimages/curl` with
`--network host`). Neither → exit `2`. (`curl` is on virtually every box, so host mode is the norm.)

### Reading the result

`RESULT: PASS — test index deleted, zero residue.` and exit `0` = every check passed and the server is
back to its pre-test state. Any failure prints the failing checks and exits `1`.

## See also

- `../README.md` — the utility-dependency overview (gating tiers, install order).
- `../../dependencies/03_Databases_datastores/06_Elasticsearch_9.4/` — the original install scripts + the
  `cluster_mode/run_book.md` native HA reference (TLS on transport + HTTP).
