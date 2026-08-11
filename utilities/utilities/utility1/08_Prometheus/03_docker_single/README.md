# Prometheus 3.12 — Docker Compose, single-node

One `prom/prometheus:v3.12.0` container via Docker Compose, configured from `.env`, with the TSDB on a
**host bind mount** so it **survives `docker compose down -v`**. Built-in expression-browser UI + HTTP API
on `:9090`, `restart: always`, runs as `nobody`. No built-in auth. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (creates + chowns the bind dir, brings the container up, polls `/-/healthy`, prints a connection
summary); and **B. Manual** — raw `docker compose` + Ubuntu commands. Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the TSDB on a bind mount
(`${DATA_ROOT}/prometheus_docker` → the container's `/prometheus`) and declares **no named volume at all**,
so:

| Command | Container | Data (`${DATA_ROOT}/prometheus_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same metrics. The *only* way to delete the data is `setup.sh purge`
(or `rm -rf ${DATA_ROOT}/prometheus_docker` by hand). Verified live: the data dir is intact after
`down -v` → `up`.

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

To run `test.sh` from the host you only need `curl` (already present on Ubuntu); the test can also fall
back to a `curlimages/curl` container if `curl` is missing.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host port if 9090 is taken
```

`.env` is gitignored; only `.env.example` is committed. Vars: `PROM_VERSION` (image tag), `PROMETHEUS_PORT`
(host port → container 9090), `PROMETHEUS_RETENTION` (`15d`), `DATA_ROOT` (`/data`). **Prometheus has no
auth, so there is no password to set** — unlike most images, a direct `docker compose up` needs **no secret
in `.env`**. The scrape config is the committed `./prometheus.yml` (scrapes itself; add targets there). If
a native Prometheus already holds `9090`, set a different `PROMETHEUS_PORT` (e.g. `9091`).

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3), creates the bind-mount data dir and `chown`s it
to `nobody` (uid `65534`, matching the container user), runs `docker compose up -d`, polls `/-/healthy`,
and ends with a **connection summary** (HTTP API + UI URL, probe URLs, the host data dir, and the browser
UI). The browser UI is `http://<host>:9090` (or your published port).

### B. Manual install (raw docker compose)

```bash
# 1. create the env file (no secret needed — Prometheus has no auth)
cp .env.example .env

# 2. create the host bind-mount data dir and chown it to the container's 'nobody' user (uid 65534)
sudo mkdir -p /data/prometheus_docker
sudo chown -R 65534:65534 /data/prometheus_docker

# 3. bring it up (reads .env for image tag + host port; mounts the committed ./prometheus.yml)
docker compose up -d

# 4. wait until healthy, then verify
docker compose ps
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9090/-/healthy   # -> 200
```

**Browser UI:** open `http://<host>:9090/` (no login — Prometheus has no built-in auth). **Status →
Targets** shows the self-scrape `UP`; the **Graph** tab runs PromQL (`up` → value `1`).

## Test

Prometheus is **pull-based**, so the contract test is a **read-only** smoke (nothing to clean up): it
checks `/-/healthy` + `/-/ready`, the build version, queries the `up` metric, and confirms a scrape target
is `up`.

### A. Scripted test

```bash
# from utility/08_Prometheus/
bash ../test.sh 03_docker_single
bash ../test.sh "http://<host>:9091"   # cross-host / non-default port
```

### B. Manual test (raw write → read → clean-up)

Prometheus has no write API, so the round-trip is exercised through the **self-scrape**: Prometheus writes
its own `up` sample into the bind-mounted TSDB and we read it back — leaving zero residue by construction.

```bash
# liveness + readiness (host curl, or 'docker compose exec prometheus wget -qO- ...' if no host curl)
curl -fsS -o /dev/null -w 'healthy=%{http_code}\n' http://127.0.0.1:9090/-/healthy   # -> healthy=200
curl -fsS -o /dev/null -w 'ready=%{http_code}\n'   http://127.0.0.1:9090/-/ready     # -> ready=200

# write→read round-trip: the self-scrape 'up' series reads back as 1
curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up' | head -c 300; echo
# -> {"status":"success",...,"value":[<ts>,"1"]...}

# UTF-8 'চাল' round-trips through PromQL unchanged (read-only, nothing stored)
curl -fsSG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=label_replace(up,"note","চাল","","")' \
  | grep -o '"note":"চাল"' | head -1                                                  # -> "note":"চাল"

# every scrape target is healthy
curl -fsS http://127.0.0.1:9090/api/v1/targets | grep -oE '"health":"[a-z]+"' | sort | uniq -c   # -> only "up"
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/prometheus_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/prometheus_docker
```

## See also

- `../README.md` — the Prometheus utility overview + how to use `test.sh` across all variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the HA variant (2 replicas + Thanos Querier).
