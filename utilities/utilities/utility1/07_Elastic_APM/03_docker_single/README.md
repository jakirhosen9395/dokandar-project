# Elastic APM stack 9.4.2 — Docker Compose, single-node (integrated 3-service stack)

Ported from [github.com/jakirhosen9395/elastic-apm](https://github.com/jakirhosen9395/elastic-apm), pinned
to **9.4.2** (DOKANDAR §8). The full APM stack in one compose, configured from `.env`:

- **elasticsearch** — data store (security ON, plain HTTP + basic auth) — `:9200`
- **kibana** — the APM app UI (logs in as `kibana_system`) — `:5601`
- **apm-server** — agent intake; config in the bind-mounted `apm-server.yml` (secret token + API key + RUM) — `:8200`

ES data is on a **host bind mount** so it **survives `docker compose down -v`**. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates the 4 secrets, stages the bring-up, sets the `kibana_system` password via the ES API,
prints a credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands (create the env +
data dir and bring it up by hand). Both produce the same stack.

## Files

- `docker-compose.yml` — `elasticsearch` + `kibana` + `apm-server`.
- `apm-server.yml` — apm-server config (RUM enabled, secret token + API key, output→ES, setup→Kibana).
- `setup.sh` — up / down / purge / status / logs.
- `.env.example` — copy to `.env`.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores ES on a bind mount
(`${DATA_ROOT}/apm_stack/es` → the image's `/usr/share/elasticsearch/data`) and declares **no named volume
at all**, so:

| Command | Containers | ES data (`${DATA_ROOT}/apm_stack/es`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (indexed traces retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same indexed traces. The *only* way to delete the data is
`setup.sh purge` (or `rm -rf ${DATA_ROOT}/apm_stack` by hand).

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

The contract test (`test.sh`) needs no client install — it uses `curl` if present, else a
`curlimages/curl` container on `--network host`.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit ports / ES_JAVA_HEAP if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `ELASTIC_VERSION` (9.4.2),
`ELASTIC_PASSWORD`, `KIBANA_PASSWORD` (the `kibana_system` password), `KIBANA_ENCRYPTION_KEY` (**must be 32
chars**), `APM_SECRET_TOKEN`, `ES_JAVA_HEAP` (1g), and the host ports `ES_HTTP_PORT` / `APM_PORT` /
`KIBANA_PORT`, plus `DATA_ROOT`. **Leave the 4 secrets empty to auto-generate them** — `setup.sh up` fills
them before `docker compose up`, shows them once, and saves them back to `.env`. **A direct
`docker compose up` needs all of `ELASTIC_PASSWORD`, `KIBANA_PASSWORD`, `KIBANA_ENCRYPTION_KEY`,
`APM_SECRET_TOKEN` set non-empty in `.env`** (the compose file `:?` -guards every one), so the manual path
sets them explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                  # auto-generates the 4 secrets, prints them, starts the stack
bash setup.sh up --gen-secrets    # rotate ELASTIC_PASSWORD / KIBANA_PASSWORD / KIBANA_ENCRYPTION_KEY / APM_SECRET_TOKEN
```

`setup.sh up` prints **numbered step output** (1/5 … 5/5), raises `vm.max_map_count`, creates the
bind-mount data dir (chown uid 1000), brings **Elasticsearch up first**, sets the **kibana_system**
password via the ES API (Kibana can't authenticate until it exists), then starts **Kibana + apm-server**,
waits for them healthy, and ends with a **credentials summary** (all endpoints + the 4 secrets — copy them
into your test env). Kibana's first boot takes ~1 minute. A no-flag re-run **reuses** the stored secrets.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET the secrets (compose :?-guards every one; the encryption key MUST be 32 chars)
cp .env.example .env
sed -i "s/^ELASTIC_PASSWORD=.*/ELASTIC_PASSWORD=ChangeMe_ElasticPassword/" .env
sed -i "s/^KIBANA_PASSWORD=.*/KIBANA_PASSWORD=ChangeMe_KibanaSystemPassword/" .env
sed -i "s/^KIBANA_ENCRYPTION_KEY=.*/KIBANA_ENCRYPTION_KEY=ChangeMe_Kibana_Encryption_Key32/" .env   # exactly 32 chars
sed -i "s/^APM_SECRET_TOKEN=.*/APM_SECRET_TOKEN=ChangeMe_ApmSecretToken/" .env

# 2. kernel tunable + the host bind-mount data dir (ES runs as uid 1000)
sudo sysctl -w vm.max_map_count=262144
sudo mkdir -p /data/apm_stack/es && sudo chown -R 1000:1000 /data/apm_stack

# 3. start Elasticsearch FIRST, wait until healthy, then set the kibana_system password via the ES API
docker compose up -d elasticsearch
until [ "$(docker inspect -f '{{.State.Health.Status}}' dokandar_apm_es 2>/dev/null)" = healthy ]; do sleep 3; done
curl -s -u "elastic:ChangeMe_ElasticPassword" -H 'content-type: application/json' -X POST \
  "http://localhost:9200/_security/user/kibana_system/_password" -d '{"password":"ChangeMe_KibanaSystemPassword"}'

# 4. bring up the rest (kibana + apm-server) — they depend_on ES being healthy
docker compose up -d

# 5. wait for apm-server :8200 (200) and Kibana healthy, then verify
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:8200/)" = 200 ]; do sleep 2; done
docker compose ps
```

Then open the **Kibana** APM app at **`http://<host>:5601/app/apm`** (log in as `elastic` /
`ChangeMe_ElasticPassword`).

## Test

The shared contract test sends a real APM intake event (a transaction with a unique `service.name`) to
`:8200`, verifies it lands in the Elasticsearch `traces-apm-*` data stream, checks Kibana is available,
then **deletes the test docs and proves zero residue**.

### A. Scripted test

```bash
# reads creds from this variant's .env:
bash ../test.sh 03_docker_single

# cross-host (test client ≠ this host) — paste the creds setup.sh printed:
APM_HOST=<host> APM_PORT=8200 ES_HTTP_PORT=9200 KIBANA_PORT=5601 \
  APM_SECRET_TOKEN=<token> ELASTIC_PASSWORD=<pw> bash ../test.sh
```

### B. Manual test (raw write → read → clean-up)

```bash
# pull the secrets from .env
set -a; . ./.env; set +a
SVC="dokandar_apmtest_$(date +%s)"; TID=$(head -c8 /dev/urandom|od -An -tx1|tr -d ' \n')
TRACE=$(head -c16 /dev/urandom|od -An -tx1|tr -d ' \n'); TSU="$(date +%s)000000"

# 1. WRITE — send an APM intake event (the transaction name carries the UTF-8 round-trip 'চাল')
printf '{"metadata":{"service":{"name":"%s","agent":{"name":"go","version":"2.0.0"},"language":{"name":"go"}}}}\n{"transaction":{"id":"%s","trace_id":"%s","type":"request","name":"GET /চাল-dokandar","duration":1.5,"timestamp":%s,"sampled":true,"span_count":{"started":0}}}\n' \
  "$SVC" "$TID" "$TRACE" "$TSU" \
  | curl -s -o /dev/null -w 'intake http=%{http_code}\n' -H "Authorization: Bearer ${APM_SECRET_TOKEN}" \
      -H 'Content-Type: application/x-ndjson' --data-binary @- "http://localhost:${APM_PORT}/intake/v2/events"   # -> 202

# 2. READ — confirm the trace landed in Elasticsearch (poll the async index)
sleep 3
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' \
  "http://localhost:${ES_HTTP_PORT}/traces-apm*/_count?ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"        # -> "count":1

# 3. CLEAN-UP — delete the test docs and prove zero residue
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' -X POST \
  "http://localhost:${ES_HTTP_PORT}/traces-apm*/_delete_by_query?refresh=true&ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' \
  "http://localhost:${ES_HTTP_PORT}/traces-apm*/_count?ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"        # -> "count":0  (zero residue)
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + apm-server reachability + host data size
bash setup.sh logs          # follow all container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the containers — ES data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/apm_stack (full wipe, indexed traces gone)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — the bind-mounted ES data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/apm_stack
```

## Notes

- **Browser UI:** **Kibana** at `http://<host>:5601` — the APM app is at `/app/apm` (log in as `elastic`).
- ES runs security ON with **plain HTTP** (HTTP TLS explicitly off) so agents/clients use basic auth over
  the SG-fenced VPC; for production, enable HTTP TLS.
- apm-server is **stateless** — it validates agent payloads (token/API key) and writes them to ES.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the HA variant (2 stateless APM Server replicas behind one ES).
</content>
</invoke>
