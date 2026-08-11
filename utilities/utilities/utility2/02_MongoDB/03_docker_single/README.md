# MongoDB 7.0 — Docker Compose, single-node

One `mongo:7.0` container run via Docker Compose, auth enabled, configured from `.env`, with data on a
**host bind mount** so it **survives `docker compose down -v`**, and `restart: always`. Tested on
Ubuntu 26.04.

> Pinned to **7.0** because `mongod` 8.x crashloops on Ubuntu / kernel 7.0 (SERVER-121912). Override with
> `MONGO_VERSION` in `.env` on a host where 8.x is safe.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates a complex password, waits for the healthcheck, enforces/rotates it via `mongosh`, prints
a credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create the env + data
dir and bring it up by hand). Both produce the same container.

## Files

- `docker-compose.yml` — the `mongo` service (bind mounts `${DATA_ROOT}/mongodb_docker/{db,configdb}`,
  healthcheck, named network `dokandar_mongo_net`, compose project `dokandar_mongodb_single`).
- `setup.sh` — up / down / purge / status / logs (auto-password, `--user`/`--db`, credentials summary).
- `.env.example` — copy to `.env`; leave `MONGO_ROOT_PASSWORD` empty to auto-generate one.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the cluster on bind mounts
(`${DATA_ROOT}/mongodb_docker/db` → the container's `/data/db`, and `.../configdb` → `/data/configdb`) and
declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/mongodb_docker`) |
| --- | --- | --- |
| `bash setup.sh down` / `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `bash setup.sh up` / `docker compose up -d` | recreated | **reused** (retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same data. The *only* way to delete the data is `setup.sh purge`
(or `rm -rf ${DATA_ROOT}/mongodb_docker` by hand). Verified live: a marker document written before
`down -v` is still present after the next `up`.

## Prerequisites — install Docker (one time)

Docker isn't in the Ubuntu base repo. Install Docker Engine + the Compose plugin from Docker's official
repo (on Ubuntu 26.04 "resolute", which Docker may not publish yet, point the repo at `noble`):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
CODENAME=$(. /etc/os-release; echo "$VERSION_CODENAME")
curl -fsI "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1 || CODENAME=noble
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

You do **not** need a host `mongosh`: `test.sh` and the manual checks below run `mongosh` straight in the
container (`docker compose exec mongo mongosh …`), and `test.sh` falls back to a throwaway `mongo:7.0`
container when no host client exists.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host port / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `MONGO_VERSION` (`7.0`), `MONGO_ROOT_USER`
(default `dokandar`), `MONGO_ROOT_PASSWORD`, `MONGO_INITDB_DATABASE`, `MONGO_PORT` (host port → container
`27017`), `DATA_ROOT`. **Leave `MONGO_ROOT_PASSWORD` empty to auto-generate a complex (24-char)
password** — `setup.sh up` fills it before `docker compose up`, shows it once, and saves it back to `.env`.
**A direct `docker compose up` needs a non-empty `MONGO_ROOT_PASSWORD` in `.env`** — the compose file
marks it required (`${MONGO_ROOT_PASSWORD:?…}`) and the image refuses to initialise an empty root password,
so the manual path sets one explicitly. If a native `mongod` already holds `27017` on the host, set a
different `MONGO_PORT` (e.g. `27018`); the container always listens on `27017` internally.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                              # auto-generates a complex password
bash setup.sh up --user dokandar --db dokandar_cart   # name the root user (first init) + create a database
bash setup.sh up --password 'MyOwnSecret'     # or set the password explicitly
bash setup.sh up --gen-password               # rotate to a fresh generated password
```

`setup.sh up` prints **numbered step output** (1/4 … 4/4): it writes the resolved credentials to `.env`
**before** `docker compose up` (the image creates the root user + enables auth on first init from
`MONGO_INITDB_ROOT_*`), creates the bind-mount data dirs (`chown 999:999` = the mongodb uid in the image),
waits for the container to be **healthy**, then **enforces/rotates the password on the running container
via `mongosh`** — so a `--gen-password` re-run rotates without redeploying. It optionally creates the
database and ends with a **credentials summary** (host, port, user, password, db, connection URI). The
password is shown once and saved to `.env`. A no-flag re-run **reuses** the stored password.

> `MONGO_INITDB_ROOT_*` only seeds the user on the **first** init (empty data dir); on existing data the
> password is enforced/rotated by `setup.sh` over the container's authenticated `mongosh`. You cannot
> rename the root user on existing data — `setup.sh` warns and keeps the original.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose REQUIRES a non-empty MONGO_ROOT_PASSWORD)
cp .env.example .env
sed -i "s/^MONGO_ROOT_PASSWORD=.*/MONGO_ROOT_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. create the host bind-mount data dirs and hand them to the image's mongodb uid (999)
sudo mkdir -p /data/mongodb_docker/db /data/mongodb_docker/configdb
sudo chown -R 999:999 /data/mongodb_docker

# 3. bring it up (reads .env for image tag, host port, user, password, db)
docker compose up -d

# 4. wait until healthy, then verify a password login
docker compose ps                                          # STATUS shows (healthy)
docker compose exec mongo mongosh --quiet \
  -u dokandar -p 'ChangeMe_StrongPassword' --authenticationDatabase admin \
  --eval 'db.runCommand({ping:1}).ok'                      # -> 1

# 5. (optional) seed an application database by hand
docker compose exec mongo mongosh --quiet \
  -u dokandar -p 'ChangeMe_StrongPassword' --authenticationDatabase admin \
  --eval "db.getSiblingDB('dokandar_cart').createCollection('_init')"
```

## Test

The shared contract test creates a throwaway `dokandar_mongotest_*` database, exercises CRUD / aggregation
/ a UNIQUE index / bilingual UTF-8, then drops everything and proves zero residue. Standalone → the
multi-document **transaction check is N/A** (expected).

### A. Scripted test

```bash
# from utility/02_MongoDB/
bash test.sh 03_docker_single                 # reads this variant's .env
# cross-host — paste the URI setup.sh printed:
bash test.sh "mongodb://dokandar:<pw>@<host>:27017/?authSource=admin&directConnection=true"
```

Runs in **host mode** if `mongosh` is on PATH, else **docker mode** (runs `mongosh` in a `mongo:7.0`
container with `--network host`).

### B. Manual test (raw write → read → clean-up)

```bash
# straight through the container (no host mongosh needed) — UTF-8 'চাল' round-trip, then drop (zero residue)
docker compose exec mongo mongosh --quiet \
  -u dokandar -p 'ChangeMe_StrongPassword' --authenticationDatabase admin <<'JS'
db = db.getSiblingDB('dokandar_smoke');
db.probe.insertOne({ name_bn: 'চাল', name_en: 'rice', at: new Date() });
printjson(db.probe.findOne({ name_en: 'rice' }));            // -> { name_bn: 'চাল', ... }
db.dropDatabase();                                           // clean up — zero residue
JS
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + user/db + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/mongodb_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/mongodb_docker
```

## Notes

- **Browser UI:** none (MongoDB ships no native web console). `mongo-express` is an optional separate
  Docker deploy you can point at this container's `mongodb://<host>:27017` — out of scope here.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the sharded HA cluster (mongos + config-RS + 2 shards).
