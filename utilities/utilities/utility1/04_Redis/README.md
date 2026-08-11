# Redis 8 — utility dependency

Redis is DOKANDAR's cache + coordination layer (cart sessions, rate-limit, Redlock, dedup, WS fan-out) —
used by `04-catalog`, `06-cart`, `07-coupon`, `14-notification`, `15-api-gateway`, `16-recommendation`.
This folder holds the install variants plus a **shared test script** that works against all of them.

> Valkey 9 is the open-BSD alternative — swap `redis-server`/`redis:8` for `valkey`/`valkey/valkey` to
> use it; the contract test is identical (same RESP protocol).

## Layout

```text
04_Redis/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (redis-cli based) — works against ALL variants
├── 01_native_single/    ← native (no Docker), systemd, env-file, data in /data/redis            [TESTED]
├── 03_docker_single/    ← Docker Compose, bind-mounted AOF data (survives `down -v`)             [TESTED]
└── 04_docker_cluster/   ← Docker Compose Redis Cluster (3 primaries + 3 replicas, 6 nodes)       [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised Redis Cluster covers HA.)

**Auth is ON** in every variant (`requirepass`; the ACL `default` user; auto-generated complex password
saved to that variant's `.env`, chmod 600). `setup.sh` prints a credentials summary; a no-flag re-run
reuses the password, `--gen-password` rotates it. Persistence is **AOF** (appendonly).

## The shared test script — `test.sh`

Uses **`redis-cli -c`** (cluster-aware; harmless on a single node), so the same script tests any variant.
It creates throwaway keys under a **hash-tagged** prefix `{dokandar_test_<ts>}` (co-located on one slot,
so it works in cluster mode), exercises strings, a counter, TTL, list, hash, set, sorted-set, and
bilingual UTF-8, then **deletes them all** and **proves zero residue** (multi-key `EXISTS` == 0).

### How to run it

```bash
bash test.sh 01_native_single     # native (reads its .env)
bash test.sh 03_docker_single     # docker single-node
bash test.sh "redis://default:<password>@<host>:7001"   # cluster (any node) / ANY server, incl. cross-host
REDIS_URL='redis://default:<pw>@host:6379' bash test.sh
```

### Run modes

`redis-cli` on `PATH` → **host mode**. No redis-cli but Docker present → **docker mode** (`redis:8`
container, `--network host`). Neither → exit `2`.

### Reading the result

`RESULT: PASS — test keys deleted, zero residue.` and exit `0` = every check passed and the keyspace is
back to its pre-test state. Any failure prints the failing checks and exits `1`.

## See also

- `../README.md` — the utility-dependency overview (gating tiers, install order).
- `../../dependencies/03_Databases_datastores/04_Redis_8/` — the original install scripts + the
  `cluster_mode/run_book.md` native Redis Cluster reference (6 nodes, failover with zero key loss).
