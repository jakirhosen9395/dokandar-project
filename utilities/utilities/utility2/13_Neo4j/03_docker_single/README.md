# Neo4j — Docker Compose single-node (Community)

One `neo4j:2026.05.0` (Community) container via Docker Compose, configured from `.env`, with data on a
**host bind mount** so it **survives `docker compose down -v`**, `restart: always`, HTTP `:7474` (built-in
**Neo4j Browser** UI), Bolt `:7687`. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates a complex password, waits for the HTTP healthcheck, verifies a Cypher query, prints a
credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create the env + data dir
and bring it up by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the graph on a bind mount
(`${DATA_ROOT}/neo4j_docker` → the image's `/data` path) and declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/neo4j_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (re-attached) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same graph. The *only* way to delete the data is `setup.sh purge`
(or `sudo rm -rf ${DATA_ROOT}/neo4j_docker` by hand). The image runs as uid `7474`; `setup.sh` (and the
manual path) chown the bind dir to `7474:7474` accordingly.

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

The shared `test.sh` only needs `curl` (it falls back to a `curlimages/curl` container if curl is absent),
so no Neo4j client packages are required on the host.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host ports / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `NEO4J_IMAGE`, `NEO4J_USER`,
`NEO4J_PASSWORD`, `NEO4J_HTTP_PORT` (host → container 7474), `NEO4J_BOLT_PORT` (host → container 7687),
`DATA_ROOT`. **Leave `NEO4J_PASSWORD` empty to auto-generate a complex (24-char) password** — `setup.sh up`
fills it before `docker compose up`, shows it once, and saves it back to `.env`. **A direct
`docker compose up` needs a non-empty `NEO4J_PASSWORD` in `.env`** — the compose file has
`NEO4J_AUTH: neo4j/${NEO4J_PASSWORD:?set in .env}` and refuses to start without it — so the manual path sets
one explicitly. If a native Neo4j already holds `7474`/`7687`, change `NEO4J_HTTP_PORT`/`NEO4J_BOLT_PORT`.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                       # auto-generates a complex password
bash setup.sh up --password 'mypass8+' # or set the password explicitly (>= 8 chars)
bash setup.sh up --gen-password        # generate a fresh password (FIRST init only — see note)
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3), creates + chowns the bind-mount data dir,
`docker compose up -d`, polls the HTTP API until live, then verifies the credentials end-to-end with a
`RETURN 1`. It ends with a **credentials summary** (HTTP/Browser URL, Bolt endpoint, user, password); the
password is shown once and saved to `.env`. A no-flag re-run **reuses** the stored password.

> **`NEO4J_AUTH` applies only at first init (Neo4j ≠ PostgreSQL).** The container reads `NEO4J_AUTH` **only
> when the data dir is empty**. There is no live `ALTER`-on-up step here, so `--gen-password` / `--password`
> only take effect on a **fresh** graph (first `up`, or after `purge`). To change the password on an
> existing graph, log in and run `ALTER CURRENT USER SET PASSWORD FROM '<old>' TO '<new>'`, or `purge` and
> re-create.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose refuses an empty NEO4J_PASSWORD — `${...:?set in .env}`)
cp .env.example .env
sed -i "s/^NEO4J_PASSWORD=.*/NEO4J_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. create + chown the host bind-mount data dir (the image runs as uid 7474)
sudo mkdir -p /data/neo4j_docker
sudo chown -R 7474:7474 /data/neo4j_docker

# 3. bring it up (reads .env for image tag, ports, password) — stock image, no --build
docker compose up -d

# 4. wait until the container is healthy, then verify (first init takes ~20-40s — POLL, don't curl too early;
#    setup.sh up loops here too. A bare query right after `up` returns 000/auth-warming until HTTP is live.)
until curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7474/ | grep -qE '200|303'; do sleep 2; done
docker compose ps                                                   # STATUS -> healthy
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7474/   # -> 200
curl -s -u neo4j:'ChangeMe_StrongPassword' -H 'content-type: application/json' \
  http://127.0.0.1:7474/db/neo4j/tx/commit -d '{"statements":[{"statement":"RETURN 1"}]}'   # -> "row":[1]
```

Once healthy, open the **Neo4j Browser** at `http://<host>:7474` and log in (connect URL
`bolt://<host>:7687`, user `neo4j`, the password you set).

## Test

The shared contract test creates a throwaway labelled subgraph (nodes + a relationship, bilingual UTF-8
props), reads it back, then `DETACH DELETE`s its own label and proves zero residue.

### A. Scripted test

```bash
# from utility/13_Neo4j/
bash ../test.sh 03_docker_single

# or drive it explicitly (curl against the host-published HTTP port; use your actual password)
NEO4J_HOST=<host> NEO4J_HTTP_PORT=7474 NEO4J_USER=neo4j NEO4J_PASSWORD='<your-password>' bash ../test.sh
```

### B. Manual test (raw write → read → clean-up)

Mirrors the contract test — a UTF-8 node create → read-back → `DETACH DELETE` → `count=0` (zero residue),
via curl against the host-published HTTP transaction API.

```bash
H=127.0.0.1; P=7474; U=neo4j; PW='<your-password>'; T=http://$H:$P/db/neo4j/tx/commit
cy(){ curl -s -u "$U:$PW" -H 'content-type: application/json' "$T" -d "{\"statements\":[{\"statement\":\"$1\"}]}"; }

cy "CREATE (:DokSmoke {id:1, name:'চাল-rice'})"      # write
cy "MATCH (n:DokSmoke {id:1}) RETURN n.name"         # read back -> "row":["চাল-rice"]
cy "MATCH (n:DokSmoke) DETACH DELETE n"              # clean up
cy "MATCH (n:DokSmoke) RETURN count(n)"              # prove zero residue -> "row":[0]
```

> Or straight through the container's bundled Bolt client (no host curl):
> `docker compose exec neo4j cypher-shell -u neo4j -p '<your-password>' --non-interactive 'RETURN 1 AS ok;'`

## Status / logs

```bash
bash setup.sh status        # docker compose ps + HTTP 200 check + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/neo4j_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/neo4j_docker
```

## See also

- `../README.md` — using `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the 3-primary Enterprise-eval HA cluster.
