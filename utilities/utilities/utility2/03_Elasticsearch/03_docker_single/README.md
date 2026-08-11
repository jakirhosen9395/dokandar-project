# Elasticsearch 9.4 — Docker Compose single-node

One `elasticsearch:9.4.2` container via Docker Compose, security ON (the built-in `elastic` user, **HTTP
basic auth over plain HTTP**, single-node → transport TLS off), configured from `.env`, with data on a
**host bind mount** so it **survives `docker compose down -v`**, `restart: always`. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (auto-generates a complex password, waits for the healthcheck, verifies/rotates it via the
`_password` API, prints a credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands
(set the password + data dir and bring it up by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the node's data on a bind mount
(`${DATA_ROOT}/elasticsearch_docker` → the image's `/usr/share/elasticsearch/data`) and declares **no
named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/elasticsearch_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same data — verified live (a marker index written before `down -v`
is still present after the next `up`). The *only* way to delete the data is `setup.sh purge` (or
`rm -rf ${DATA_ROOT}/elasticsearch_docker` by hand).

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

The shared `test.sh` uses `curl` (already on virtually every box) — no Elasticsearch client to install.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host port / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `ES_IMAGE_TAG` (`9.4.2`), `ELASTIC_PASSWORD`,
`ES_CLUSTER_NAME`, `ES_JAVA_HEAP` (`512m`), `ES_HTTP_PORT` (host port → container `9200`), `DATA_ROOT`.
**Leave `ELASTIC_PASSWORD` empty to auto-generate a complex (24-char) password** — `setup.sh up` fills it
**before** `docker compose up`, shows it once, and saves it back to `.env`. **A direct `docker compose up`
needs a non-empty `ELASTIC_PASSWORD` in `.env`** (the compose file marks it required with `:?` and the
image seeds the `elastic` user on first init), so the manual path sets one explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up                  # auto-generates a complex password
bash setup.sh up --password 'MyOwnSecret'   # or set the password explicitly
bash setup.sh up --gen-password   # rotate the elastic password (via the _password API)
```

`setup.sh up` prints **numbered step output** (1/4 … 4/4): raises `vm.max_map_count`, creates + `chown`s
the bind dir to **uid 1000**, writes the password to `.env` **before** `docker compose up`, waits for
**healthy**, then verifies (or rotates with `--gen-password`) the `elastic` password and prints a
**credentials summary** (REST endpoint, user, password, connection URL, `curl` command). The password is
shown once and saved to `.env`. A no-flag re-run reuses the stored password.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose requires a non-empty ELASTIC_PASSWORD via :?)
cp .env.example .env
sed -i "s/^ELASTIC_PASSWORD=.*/ELASTIC_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. host prereq + the bind-mount data dir, owned by the image's uid 1000 (the elasticsearch user)
sudo sysctl -w vm.max_map_count=262144
sudo mkdir -p /data/elasticsearch_docker
sudo chown -R 1000:1000 /data/elasticsearch_docker

# 3. bring it up (reads .env for image tag, host port, password, heap)
docker compose up -d

# 4. wait until healthy, then verify with auth
docker compose ps        # STATUS shows "healthy" after ~30s
docker compose exec elasticsearch \
  curl -s -u elastic:ChangeMe_StrongPassword http://localhost:9200/_cluster/health?pretty | grep '"status"'   # -> green
```

If a native Elasticsearch already holds `9200` on this host, set a different `ES_HTTP_PORT` (e.g. `9201`)
in `.env` before bringing it up.

## Test

The shared contract test creates a throwaway `dokandar_estest_<ts>` index, exercises mapping/bulk/UTF-8/
search/aggregation/update, then deletes the index and proves zero residue.

### A. Scripted test

```bash
# from utility/03_Elasticsearch/
bash test.sh 03_docker_single

# or drive it explicitly (use your actual password / host port)
bash test.sh "http://elastic:<your-password>@127.0.0.1:9200"
```

### B. Manual test (raw write → read → clean-up)

```bash
PW=ChangeMe_StrongPassword; IDX=dokandar_smoke
# straight through the container (no host Elasticsearch client needed)
docker compose exec elasticsearch curl -s -u elastic:$PW -X POST "http://localhost:9200/$IDX/_doc/1?refresh=wait_for" \
  -H 'Content-Type: application/json' -d '{"name_bn":"চাল","name_en":"rice"}'
# read it back (proves the UTF-8 round-trip)
docker compose exec elasticsearch curl -s -u elastic:$PW "http://localhost:9200/$IDX/_doc/1?filter_path=_source.name_bn"   # -> {"_source":{"name_bn":"চাল"}}
# delete the index (zero residue) and confirm it is gone
docker compose exec elasticsearch curl -s -u elastic:$PW -X DELETE "http://localhost:9200/$IDX" >/dev/null
docker compose exec elasticsearch curl -s -o /dev/null -w '%{http_code}\n' -u elastic:$PW "http://localhost:9200/$IDX"    # -> 404
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + user + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/elasticsearch_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/elasticsearch_docker
```

## Notes

- **Browser UI:** none (Kibana is a separate companion — point its `elasticsearch.hosts` at this node and
  browse it on `:5601`).
- `bootstrap.memory_lock=true` + the `memlock` ulimit keep ES off swap; the heap is `ES_JAVA_HEAP` (512m).

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the Docker Compose 3-node HA cluster.
