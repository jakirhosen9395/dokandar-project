# RustFS — utility dependency

RustFS is DOKANDAR's **S3-compatible object store** — the media/blob backend for `12-media`. It **replaces
MinIO** (whose community edition is frozen; CLAUDE.md §2 names RustFS / Garage as the exit path). Because
`12-media` targets the S3 API, the swap is config-only. Ported from the `dokandar/utilities/components`
`rustfs/` reference. This folder holds the install variants plus a **shared test script** for all of them.

## Layout

```text
10_RustFS/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (S3 API, via the mc client) — works against ALL variants
├── 01_native_single/    ← native (no Docker), static binary + systemd, single drive /data/rustfs          [TESTED]
├── 03_docker_single/    ← Docker Compose, single drive bind-mounted (survives down -v)                     [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: 4 nodes x 1 drive, distributed erasure set                    [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 4-node distributed cluster covers HA.)

> **Auth.** RustFS uses an S3 **access key** (20 hex) + **secret key** (40 hex). Each variant's `setup.sh`
> **auto-generates** them when `.env`'s are empty (or `--gen-keys`), accepts `--access`/`--secret`, and
> **prints them to the console** (copy them into your test env) + saves them to that variant's `.env`
> (chmod 600). The built-in **console** (`:9001`) is the browser UI. TLS off (dev) — restrict at the
> firewall; tests run over an SG-fenced VPC.

## The shared test script — `test.sh`

Uses the **`mc`** client (RustFS is S3-compatible). DEEP contract: lists buckets (auth) → creates a
throwaway bucket → PUTs 2 UTF-8 objects → GETs them back → asserts the list count → stats → server-side
copies → then removes everything and proves **zero residue**. **Dual-mode**: reads creds from a variant's
`.env`, or from env vars you paste from `setup.sh`'s output — point it at a **different host** than the one
running RustFS to prove cross-host access.

### How to run it

```bash
bash test.sh 01_native_single     # native (reads keys + port from its .env)
# or against ANY RustFS (e.g. cross-host) — paste the keys setup.sh printed:
RUSTFS_HOST=<host> RUSTFS_ACCESS_KEY=<ak> RUSTFS_SECRET_KEY=<sk> bash test.sh
```

Client auto-selects: **host** `mc` if on PATH, else a **`minio/mc`** Docker container (`--network host`).

### Reading the result

`RESULT: PASS — objects put/got/copied/removed, zero residue.` and exit `0` means the S3 API + keys work and
the namespace is clean.

## See also

- `../README.md` — the utility-dependency overview.
- `../../dependencies/03_Databases_datastores/11_MinIO/` — the prior MinIO install layer (RustFS is the exit path).
