# MongoDB 7.0 — utility dependency

MongoDB is DOKANDAR's document store: the `06-cart` and `14-notification` services' primary datastore, and
the platform-wide application-log sink (`mongo_db_dokandar_application_logs.<service>`). This folder holds
the install variants plus a **shared test script** that works against all of them.

> **Why 7.0 here (not the platform's 8.0/8.3 pin).** `mongod` **8.x segfault-crashloops on Ubuntu /
> kernel 7.0** (`MongoDB cannot start: Linux kernel versions 6.19 and newer has a known incompatibility`,
> upstream **SERVER-121912**). **7.0 predates that incompatibility and runs cleanly** — it is the README §9
> components-stack pin for Ubuntu hosts. Production targets **8.0/8.3 on AL2023 hosts** where the kernel
> block does not apply. Every variant takes `MONGO_VERSION` (default `7.0`) so you can raise it on a
> compatible host. Verified live on AWS (Ubuntu, kernel `7.0.0-aws`): 7.0 single + replica set + a
> multi-document transaction all pass; 8.0 exits immediately.

## Layout

```text
02_MongoDB/
├── README.md            ← this file (how to use test.sh for every variant)
├── test.sh              ← shared contract/smoke test — works against ALL variants, host OR docker mode
├── 01_native_single/    ← native (no Docker), systemd, env-file, data in /data/mongodb        [TESTED]
├── 03_docker_single/    ← Docker Compose, bind-mounted data (survives `down -v`)               [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA replica set rs0 (1 primary + 2 secondaries)        [TESTED]
```

(`02_native_cluster` is intentionally skipped for this tool — the Dockerised replica set covers HA.)

Each variant folder has its own `setup.sh` / `docker-compose.yml`, `.env.example`, and `README.md`. Start
there to install, then come back here to test.

**Each variant's `setup.sh install`/`up` auto-generates a complex (24-char) password** when `.env`'s is
empty or `--gen-password` is passed (`--password X` to set it; `--user NAME` / `--db NAME` to name the
root user and create a database). It prints step-by-step status and ends with a **credentials summary**
(host / port / user / password / connection URI). The password is saved to that variant's `.env`
(chmod 600); a no-flag re-run **reuses** it — and `test.sh` reads it from there. Auth is always on
(`authSource=admin`, built-in `root` role); the cluster additionally uses a shared **keyFile** for
internal replica-set auth.

## The shared test script — `test.sh`

`test.sh` runs the whole contract as a single `mongosh` program against the target and prints a PASS/FAIL
report. It:

1. confirms connectivity **and authentication** (`listDatabases`, which — unlike `ping` — needs auth);
2. creates a throwaway `dokandar_mongotest_<ts>` database and exercises CRUD, bilingual UTF-8, an
   aggregation pipeline, a **UNIQUE index** (and its duplicate rejection);
3. on a **replica set**, runs a **multi-document transaction** (auto-detected via `db.hello().setName`;
   marked **N/A** on a standalone, where transactions are not supported);
4. **drops the throwaway database** (trap-guarded) and **proves zero residue**;
5. writes the summary to `test-result.txt` and exits non-zero on any failure.

It never touches a pre-existing database — only its own `dokandar_mongotest_*` one.

### How to run it (works for all variants)

Pass the **variant folder** — `test.sh` reads that variant's `.env` for the connection:

```bash
bash test.sh 01_native_single     # native (no Docker)
bash test.sh 03_docker_single     # Docker Compose single-node
bash test.sh 04_docker_cluster    # Docker Compose HA replica set (connects to the primary)
```

**To test ANY MongoDB server** (e.g. from a *different* machine), give a connection URI (or set
`MONGO_URL`), or save it once in a `.env` beside this script:

```bash
bash test.sh "mongodb://user:pass@host:27017/?authSource=admin&directConnection=true"
MONGO_URL='mongodb://user:pass@host:27017/?authSource=admin' bash test.sh
cp .env.example .env    # then set MONGO_URL= (or MONGO_* parts) in it, and just:  bash test.sh
```

The URI's database is ignored — the test creates + drops its own throwaway `dokandar_mongotest_*`. Use
`directConnection=true` to pin a single node (required when testing a replica set through one published
port whose internal members are named, not routable from the client).

With no argument it resolves, in order: a URI (`MONGO_URL`) → this folder's `.env` → the first
`NN_*/.env` present → parts (`MONGO_HOST`/`MONGO_PORT`/`MONGO_ROOT_USER`/`MONGO_ROOT_PASSWORD`,
defaults `127.0.0.1:27017`, `authSource=admin`).

### Two run modes (auto-selected)

The script prints its mode on the first line (`[mode=host]` or `[mode=docker mongo:<ver>]`):

- **host mode** — when `mongosh` is on `PATH` (the native `setup.sh` installs it). Connects directly.
- **docker mode** — when there is **no host `mongosh`** but Docker is present: it runs `mongosh` inside a
  `mongo:<ver>` container with `--network host`, so `127.0.0.1:<port>` reaches a locally published server
  **and** a remote `host:port` is reachable just as from the host. Needs zero host packages — this is how
  the cross-host tests run from a client box that only has Docker.

If neither a client nor Docker is available it fails fast with exit `2`.

### Reading the result

`RESULT: PASS — throwaway database dropped, zero residue.` and exit `0` means every check passed and the
server is back to exactly its pre-test state. Any failure prints the failing checks and exits `1`.

## See also

- `../README.md` — the utility-dependency overview (gating tiers, install order).
- `../../dependencies/03_Databases_datastores/05_MongoDB_8.0/` — the original install scripts + the
  `cluster_mode/run_book.md` HA reference (native replica set; pinned 8.0, hence RECORD-ONLY on this kernel).
