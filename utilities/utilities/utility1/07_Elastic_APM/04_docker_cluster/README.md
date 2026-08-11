# Elastic APM 9.4 — Docker Compose HA (ES + 2 APM Server replicas + Kibana)

The integrated stack with **APM Server made highly available** the way APM actually scales — **two
stateless APM Server replicas** (`apm-1` :8200, `apm-2` :8201) both ingesting agent traffic and writing to
the same Elasticsearch, with Kibana for the APM app. Configured from `.env`; ES data on a **host bind
mount** that survives `docker compose down -v`. Tested on Ubuntu 26.04.

## Topology

| Service | Container | Port | Role |
| --- | --- | --- | --- |
| elasticsearch | `dokandar_apm_es` | 9200 | storage |
| apm-1 | `dokandar_apm_1` | 8200 | APM ingest (stateless replica) |
| apm-2 | `dokandar_apm_2` | 8201 | APM ingest (stateless replica) |
| kibana | `dokandar_apm_kibana` | 5601 | the APM app UI |

```text
   agents ─┬─► apm-1 :8200 ─┐
           │                ├─► elasticsearch :9200 ◄── kibana :5601 (APM app)
           └─► apm-2 :8201 ─┘        (storage)
```

> **Why replicas, not a "cluster".** APM Server holds no state — it validates agent payloads and writes
> them to Elasticsearch — so its HA is **horizontal replicas behind a load balancer**, not a stateful
> cluster. This variant runs **2 replicas** to demonstrate that. The stateful HA (the data) belongs to
> **Elasticsearch**: for a fully HA backend, point these replicas at a 3-node ES cluster
> (`../../03_Elasticsearch/04_docker_cluster`) instead of the single ES here.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the ES + `kibana_system` passwords + the APM secret token, stages the bring-up, prints a
credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands.

## Files

- `docker-compose.yml` — `elasticsearch` + `apm-1` + `apm-2` + `kibana`.
- `setup.sh` — up / down / purge / status / **acceptance** / logs.
- `.env.example` — copy to `.env`.

## Data persistence (why the data survives `down -v`)

ES data is a **host bind mount** (`${DATA_ROOT}/apm_stack/es` → the image's
`/usr/share/elasticsearch/data`), and there is **no named volume**, so:

| Command | Containers | ES data (`${DATA_ROOT}/apm_stack/es`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (indexed traces retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

## Prerequisites

Docker Engine + the Compose plugin (see `../03_docker_single/README.md` for the install). The contract
test (`test.sh`) needs no client install — it uses `curl` if present, else a `curlimages/curl` container.

## Configure

```bash
cp .env.example .env        # required — setup.sh exits if .env is missing; edit ports / ES_JAVA_HEAP if needed
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `ELASTIC_VERSION` (9.4.2),
`ELASTIC_PASSWORD`, `KIBANA_SYSTEM_PASSWORD`, `APM_SECRET_TOKEN`, `ES_JAVA_HEAP` (512m), and the host ports
`ES_HTTP_PORT` (9200) / `APM_PORT` (8200) / `APM_PORT2` (8201) / `KIBANA_PORT` (5601), plus `DATA_ROOT`.
**Leave the three secrets empty to auto-generate them** — `setup.sh up` fills them before
`docker compose up`. **A direct `docker compose up` needs `ELASTIC_PASSWORD`, `KIBANA_SYSTEM_PASSWORD`, and
`APM_SECRET_TOKEN` set non-empty in `.env`** (the compose file `:?`-guards each), so the manual path sets
them explicitly. Both APM replicas read the **same** secret token and ES output creds via the compose
`command -E` flags — there is no per-replica state.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                  # ES first, set kibana_system password, then Kibana + both APM replicas
bash setup.sh up --gen-password   # rotate the ES + kibana_system passwords
```

`setup.sh up` prints **numbered step output** (1/4 … 4/4), raises `vm.max_map_count`, creates the
bind-mount data dir (chown uid 1000), brings **Elasticsearch up first**, sets the **kibana_system**
password via the ES API, then starts **Kibana + both APM replicas**, waits for `:8200` and `:8201` to
answer 200 and Kibana healthy, and ends with a **credentials summary** (both APM endpoints + the ES
endpoint + Kibana URL). Secrets are shown once and saved to `.env`. **Replication is fully automatic on
`up` — both replicas come up stateless; there is no manual cluster-init step.**

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET the secrets (compose :?-guards each; both APM replicas share them)
cp .env.example .env
sed -i "s/^ELASTIC_PASSWORD=.*/ELASTIC_PASSWORD=ChangeMe_ElasticPassword/" .env
sed -i "s/^KIBANA_SYSTEM_PASSWORD=.*/KIBANA_SYSTEM_PASSWORD=ChangeMe_KibanaSystemPassword/" .env
sed -i "s/^APM_SECRET_TOKEN=.*/APM_SECRET_TOKEN=ChangeMe_ApmSecretToken/" .env

# 2. kernel tunable + the host bind-mount data dir (ES runs as uid 1000)
sudo sysctl -w vm.max_map_count=262144
sudo mkdir -p /data/apm_stack/es && sudo chown -R 1000:1000 /data/apm_stack

# 3. start Elasticsearch FIRST, wait until healthy, then set the kibana_system password via the ES API
docker compose up -d elasticsearch
until [ "$(docker inspect -f '{{.State.Health.Status}}' dokandar_apm_es 2>/dev/null)" = healthy ]; do sleep 3; done
curl -s -u "elastic:ChangeMe_ElasticPassword" -H 'content-type: application/json' -X POST \
  "http://localhost:9200/_security/user/kibana_system/_password" -d '{"password":"ChangeMe_KibanaSystemPassword"}'

# 4. bring up Kibana + BOTH APM replicas (they depend_on ES being healthy — no manual cluster init)
docker compose up -d

# 5. wait for both replicas to answer 200, then verify all containers
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:8200/)" = 200 ]; do sleep 2; done
until [ "$(curl -s -o /dev/null -w '%{http_code}' --max-time 3 http://localhost:8201/)" = 200 ]; do sleep 2; done
docker compose ps
```

Then open the **Kibana** APM app at **`http://<host>:5601/app/apm`** (log in as `elastic`). Put a load
balancer in front of `:8200`/`:8201` so agents get a single, HA ingest endpoint.

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh acceptance      # sends an event through EACH replica (:8200 and :8201) and confirms both
                              # reach Elasticsearch, then deletes each test doc (zero residue)
```

Prints `OK: apm-1 event reached ES` and `OK: apm-2 event reached ES` when **both** stateless replicas
independently ingest to the shared Elasticsearch.

### B. Manual acceptance (send through each replica → assert both reach ES)

```bash
set -a; . ./.env; set +a
for PR in "${APM_PORT:-8200}:apm-1" "${APM_PORT2:-8201}:apm-2"; do
  P="${PR%%:*}"; N="${PR##*:}"; SVC="ha_check_${N}_$$"
  TID=$(head -c8 /dev/urandom|od -An -tx1|tr -d ' \n'); TRACE=$(head -c16 /dev/urandom|od -An -tx1|tr -d ' \n'); TSU="$(date +%s)000000"
  # send a 'চাল' transaction through THIS replica
  printf '{"metadata":{"service":{"name":"%s","agent":{"name":"go","version":"2.0.0"}}}}\n{"transaction":{"id":"%s","trace_id":"%s","type":"request","name":"GET /চাল-%s","duration":1,"timestamp":%s,"span_count":{"started":0}}}\n' \
    "$SVC" "$TID" "$TRACE" "$N" "$TSU" \
    | curl -s -o /dev/null -w "   ${N} (:${P}) intake http=%{http_code}\n" -H "Authorization: Bearer ${APM_SECRET_TOKEN}" \
        -H 'Content-Type: application/x-ndjson' --data-binary @- "http://localhost:${P}/intake/v2/events"
  sleep 3
  # assert it reached the shared ES, then delete it (zero residue)
  curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' \
    "http://localhost:${ES_HTTP_PORT:-9200}/traces-apm*/_count?ignore_unavailable=true" \
    -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"          # -> "count":1  (this replica reached ES)
  curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' -X POST \
    "http://localhost:${ES_HTTP_PORT:-9200}/traces-apm*/_delete_by_query?refresh=true&ignore_unavailable=true" \
    -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}" >/dev/null
done
```

## Test (the shared contract test, through replica 1)

### A. Scripted test

```bash
# from utility/07_Elastic_APM/  (reads this variant's .env — APM_PORT = replica 1)
bash ../test.sh 04_docker_cluster

# cross-host — paste the creds setup.sh printed:
APM_HOST=<host> APM_SECRET_TOKEN=<token> ELASTIC_PASSWORD=<pw> bash ../test.sh
```

The test sends a real APM intake event to `:8200`, verifies the trace lands in Elasticsearch
(`traces-apm-*`), checks Kibana is available, then deletes the test docs and proves **zero residue**.

### B. Manual test (raw write → read → clean-up, through replica 1)

```bash
set -a; . ./.env; set +a
SVC="dokandar_apmtest_$(date +%s)"; TID=$(head -c8 /dev/urandom|od -An -tx1|tr -d ' \n')
TRACE=$(head -c16 /dev/urandom|od -An -tx1|tr -d ' \n'); TSU="$(date +%s)000000"

# 1. WRITE — APM intake event through replica 1 (transaction name carries the UTF-8 round-trip 'চাল')
printf '{"metadata":{"service":{"name":"%s","agent":{"name":"go","version":"2.0.0"},"language":{"name":"go"}}}}\n{"transaction":{"id":"%s","trace_id":"%s","type":"request","name":"GET /চাল-dokandar","duration":1.5,"timestamp":%s,"sampled":true,"span_count":{"started":0}}}\n' \
  "$SVC" "$TID" "$TRACE" "$TSU" \
  | curl -s -o /dev/null -w 'intake http=%{http_code}\n' -H "Authorization: Bearer ${APM_SECRET_TOKEN}" \
      -H 'Content-Type: application/x-ndjson' --data-binary @- "http://localhost:${APM_PORT:-8200}/intake/v2/events"   # -> 202

# 2. READ — confirm the trace landed in Elasticsearch
sleep 3
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' \
  "http://localhost:${ES_HTTP_PORT:-9200}/traces-apm*/_count?ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"          # -> "count":1

# 3. CLEAN-UP — delete the test docs and prove zero residue
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' -X POST \
  "http://localhost:${ES_HTTP_PORT:-9200}/traces-apm*/_delete_by_query?refresh=true&ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' \
  "http://localhost:${ES_HTTP_PORT:-9200}/traces-apm*/_count?ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"          # -> "count":0  (zero residue)
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + host data size
bash setup.sh logs          # follow all container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 4 containers — ES data PRESERVED
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

- **Browser UI:** **Kibana** at `http://<host>:5601` (APM app at `/app/apm`; log in as `elastic`).
- Put a load balancer in front of `:8200`/`:8201` so agents get a single, HA ingest endpoint.
- For a fully HA backend, point both replicas at a 3-node Elasticsearch cluster instead of the single ES.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` and `../03_docker_single/` — the native and single-node Docker variants.
</content>
</invoke>
