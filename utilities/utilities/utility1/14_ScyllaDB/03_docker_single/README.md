# ScyllaDB 2026.1 — Docker Compose, single-node

One `scylladb/scylla:2026.1` container via Docker Compose, configured from `.env`, with data on a **host
bind mount** so it **survives `docker compose down -v`**, `restart: always`, CQL on `:9042`. It runs in
**developer mode** with capped `--smp 1`/`--memory 1G` so it starts on a shared box without the invasive
`scylla_setup` host tuning. ScyllaDB ships with the **authenticator off** (no username/password) and has
**no browser UI** — interact via **`cqlsh`** / **`nodetool`**. Tested on Ubuntu 26.04, local + cross-host.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (creates the bind dir, brings it up, polls for CQL, prints a connection summary); and **B. Manual** —
raw `docker compose` + Ubuntu commands. Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a **bind
mount** (a host directory). This compose file stores the data on a bind mount
(`${DATA_ROOT}/scylla_docker` → the image's `/var/lib/scylla`) and declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/scylla_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (re-attached) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same keyspaces. The *only* way to delete the data is `setup.sh purge`
(or `sudo rm -rf ${DATA_ROOT}/scylla_docker` by hand).

## Prerequisites — install Docker (one time)

Docker isn't in the Ubuntu base repo. Install Docker Engine + the Compose plugin from Docker's official repo
(on Ubuntu 26.04 "resolute", which Docker may not publish yet, point the repo at `noble`):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
CODENAME=$(. /etc/os-release; echo "$VERSION_CODENAME")
curl -fsI "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1 || CODENAME=noble
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

You do **not** need a host CQL client — `test.sh` and the manual test below run `cqlsh` **inside** the
container (or in a throwaway `scylladb/scylla` container with `--network host`).

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit image tag / host CQL port if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `SCYLLA_IMAGE` (default
`scylladb/scylla:2026.1`), `SCYLLA_CLUSTER_NAME` (default `dokandar`), `SCYLLA_CQL_PORT` (host port →
container `9042`, default `9042`), `DATA_ROOT` (default `/data`). **There is no password to set** —
ScyllaDB's authenticator is off by default, so the image starts with an empty `.env` (no required secret).
If a native ScyllaDB already holds `9042`, change `SCYLLA_CQL_PORT`.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up               # ScyllaDB boot is slow (~30-60s) — the script polls until CQL answers
```

`setup.sh up` (3 steps): creates the bind-mount data dir and chowns it to the image's uid `999` →
`docker compose up -d` and polls until CQL answers → verifies `nodetool status` (`UN`) + `release_version`,
then prints a **connection summary** (CQL endpoint, the `Auth: none` note, the `cqlsh` smoke command, the
host data dir).

### B. Manual install (raw docker compose)

```bash
# 1. create the env file (no secret to set — ScyllaDB has no auth by default)
cp .env.example .env

# 2. create the host bind-mount data dir and chown it to the image's scylla uid (999)
sudo mkdir -p /data/scylla_docker
sudo chown -R 999:999 /data/scylla_docker

# 3. bring it up (reads .env for image tag + host CQL port; boot is slow ~30-60s)
docker compose up -d

# 4. BLOCK until CQL answers — ScyllaDB boots slowly (~30-60s); without this wait the next
#    nodetool/cqlsh lines run mid-boot and error ("Has this node finished starting up?"). Mirror of setup.sh.
until docker exec dokandar_scylla_docker_single cqlsh -e "SELECT now() FROM system.local;" >/dev/null 2>&1; do sleep 3; done

# 5. verify
docker compose ps                                        # STATUS -> healthy
docker exec dokandar_scylla_docker_single nodetool status            # -> one UN node
docker exec dokandar_scylla_docker_single cqlsh -e "SELECT release_version FROM system.local;"
```

## Test

The shared contract test creates a throwaway `dokandar_test_*` keyspace, inserts bilingual-UTF-8 rows, reads
them back (count / value), then drops the keyspace and proves zero residue.

### A. Scripted test

```bash
# from utility/14_ScyllaDB/
bash test.sh 03_docker_single

# or against ANY ScyllaDB (e.g. cross-host):
SCYLLA_HOST=<host> SCYLLA_CQL_PORT=9042 bash test.sh
```

The client auto-selects: host `cqlsh` if on PATH, else `cqlsh` inside a `scylladb/scylla` Docker container
(`--network host`) — so this variant tests with zero host packages.

### B. Manual test (raw write → read → clean-up)

```bash
# straight through the container (no host cqlsh needed) — mirror of test.sh
docker exec dokandar_scylla_docker_single cqlsh -e "
CREATE KEYSPACE dokandar_smoke WITH replication = {'class':'SimpleStrategy','replication_factor':1};
USE dokandar_smoke;
CREATE TABLE t (id int PRIMARY KEY, name text);
INSERT INTO t (id,name) VALUES (1,'চাল-rice');
SELECT name FROM t WHERE id=1;"                          # -> চাল-rice

# clean up + prove zero residue
docker exec dokandar_scylla_docker_single cqlsh -e "DROP KEYSPACE dokandar_smoke;"
docker exec dokandar_scylla_docker_single cqlsh -e "SELECT keyspace_name FROM system_schema.keyspaces WHERE keyspace_name='dokandar_smoke';"  # -> (0 rows)
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + CQL reachability + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/scylla_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/scylla_docker
```

## Notes

- **No browser UI** — ScyllaDB is a CQL database; interact via `cqlsh` / `nodetool`.
- Developer mode + capped `--smp 1`/`--memory 1G` make it fit a shared box. Single node = no replication —
  see `../04_docker_cluster/` for the 3-node ring at `replication_factor=3`.

## See also

- `../README.md` — the utility ScyllaDB overview + how `test.sh` works across all variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the Docker HA 3-node ring.
