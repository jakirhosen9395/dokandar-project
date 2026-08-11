# Elastic APM 9.4 — native single-node (integrated stack, no Docker)

The full APM stack installed **natively** on an Ubuntu host (Elastic 9.x apt repo, all via systemd,
**no Docker**): **Elasticsearch** (`:9200`, storage) + **APM Server** (`:8200`, agent ingest) + **Kibana**
(`:5601`, the APM app UI). ES security is **ON** (HTTP basic auth, HTTP TLS deliberately off); APM Server
and Kibana authenticate to ES. Data lives under `/data/apm_stack/es` (preserved on uninstall). Tested on
**Ubuntu 26.04 (resolute)**.

- **What runs:** `elasticsearch` + `kibana` + `apm-server` (pinned `9.4.*`), three systemd units.
- **Data:** `${DATA_ROOT}/apm_stack/es` (default `/data/apm_stack/es`), symlinked from
  `/var/lib/elasticsearch`. Install is **non-destructive**; uninstall **keeps the data** (only `purge`
  deletes it).
- **Browser UI:** **Kibana** at `http://<host>:5601` (the APM app at `/app/apm`; log in as `elastic`).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates the ES + `kibana_system` passwords + the APM secret token, prints a credentials
summary); and **B. Manual** — raw copy-paste Ubuntu commands that run the exact same steps by hand, no
script. Both produce the same stack.

## Files

- `setup.sh` — install / uninstall / purge / status.
- `.env.example` — copy to `.env`.

## Configure

```bash
cp .env.example .env        # optional — edit ports / ES_JAVA_HEAP; leave the secrets EMPTY to auto-generate
```

`.env` is gitignored (it holds the real secrets); only `.env.example` is committed. Key vars:
`ELASTIC_VERSION` (9.4), `ELASTIC_PASSWORD`, `KIBANA_SYSTEM_PASSWORD`, `APM_SECRET_TOKEN`, `ES_JAVA_HEAP`
(512m), `ES_HTTP_PORT` (9200), `APM_PORT` (8200), `KIBANA_PORT` (5601), `DATA_ROOT` (/data). **Leave the
three secrets empty to auto-generate them on install** — they are shown once and saved back to `.env`. With
the script you can skip the edit entirely; with the manual path you choose the secrets yourself below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                 # auto-generates ES + kibana_system passwords + APM secret token
sudo bash setup.sh install --gen-password  # rotate the ES + kibana_system passwords
```

Prints **numbered step output** (1/6 … 6/6 with ✓ ticks) and ends with a **credentials summary** — the
APM ingest endpoint + secret token, the Elasticsearch endpoint (`elastic` / password), and the Kibana UI
URL. The secrets are **shown once** and persisted to `.env` (chmod 600). Idempotent: raises
`vm.max_map_count`, adds the Elastic 9.x repo, prepares `/data/apm_stack/es`, installs the three packages,
configures ES (security on, HTTP TLS off, single-node), sets the `elastic` + `kibana_system` passwords,
points Kibana and APM Server at ES, and verifies. **Kibana's first boot takes ~1 minute.**

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
secrets where shown. **Do the `/var/lib/elasticsearch` → `/data` symlink in step 3 *before* starting ES**,
so the indices land on `/data` rather than the root disk.

```bash
# 1. kernel tunable for Elasticsearch + the Elastic 9.x apt repo (GPG-signed)
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-dokandar-apm.conf
sudo apt-get install -y wget gnupg curl ca-certificates apt-transport-https
sudo install -d -m 0755 /etc/apt/keyrings
wget -qO- https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/elastic.gpg
echo "deb [signed-by=/etc/apt/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-9.x.list
sudo apt-get update -y

# 2. install Elasticsearch + Kibana + APM Server (all pinned to 9.4)
sudo apt-get install -y "elasticsearch=9.4.*" "kibana=9.4.*" apm-server

# 3. point the ES data dir at /data BEFORE first start (non-destructive)
sudo mkdir -p /data/apm_stack/es
sudo systemctl stop elasticsearch 2>/dev/null || true
sudo rm -rf /var/lib/elasticsearch && sudo ln -sfn /data/apm_stack/es /var/lib/elasticsearch
sudo chown -R elasticsearch:elasticsearch /data/apm_stack/es

# 4. Elasticsearch config — small heap + security on, HTTP TLS off, single-node
sudo mkdir -p /etc/elasticsearch/jvm.options.d
printf -- '-Xms512m\n-Xmx512m\n' | sudo tee /etc/elasticsearch/jvm.options.d/heap.options
sudo sed -i '/BEGIN SECURITY AUTO CONFIGURATION/,/END SECURITY AUTO CONFIGURATION/d' /etc/elasticsearch/elasticsearch.yml
sudo tee -a /etc/elasticsearch/elasticsearch.yml >/dev/null <<'YML'
# >>> dokandar managed >>>
cluster.name: dokandar-apm
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
xpack.security.enabled: true
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
# <<< dokandar managed <<<
YML
sudo systemctl daemon-reload && sudo systemctl enable --now elasticsearch
# wait for ES to answer (security is on, so a plain GET / returns 401 — that is "up")
until curl -s --max-time 3 http://localhost:9200 >/dev/null; do sleep 3; done

# 5. set the elastic + kibana_system passwords (pick your own; the bootstrap reset prints a temp one)
BOOT=$(sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -a -b -s | tr -d '[:space:]')
curl -s -u "elastic:$BOOT" -X POST http://localhost:9200/_security/user/elastic/_password \
  -H 'content-type: application/json' -d '{"password":"ChangeMe_ElasticPassword"}'
curl -s -u 'elastic:ChangeMe_ElasticPassword' -X POST http://localhost:9200/_security/user/kibana_system/_password \
  -H 'content-type: application/json' -d '{"password":"ChangeMe_KibanaSystemPassword"}'

# 6. Kibana → Elasticsearch (logs in as kibana_system)
sudo tee -a /etc/kibana/kibana.yml >/dev/null <<'YML'
server.host: "0.0.0.0"
server.port: 5601
elasticsearch.hosts: ["http://localhost:9200"]
elasticsearch.username: "kibana_system"
elasticsearch.password: "ChangeMe_KibanaSystemPassword"
YML
sudo systemctl enable --now kibana          # first boot takes ~1 min

# 7. APM Server → Elasticsearch (:8200, secret token, elastic output creds)
YML=/etc/apm-server/apm-server.yml
sudo sed -i -E 's|^([[:space:]]*)host:[[:space:]]*"?[^"]*:[0-9]+"?[[:space:]]*$|\1host: "0.0.0.0:8200"|' "$YML"
sudo sed -i -E 's|^([[:space:]]*)hosts:[[:space:]]*\["localhost:9200"\][[:space:]]*$|\1hosts: ["localhost:9200"]|' "$YML"
printf '\napm-server.auth.secret_token: "ChangeMe_ApmSecretToken"\noutput.elasticsearch.username: "elastic"\noutput.elasticsearch.password: "ChangeMe_ElasticPassword"\n' | sudo tee -a "$YML"
sudo systemctl enable --now apm-server

# 8. save the chosen secrets to .env (the script does this; the Manual test below reads them from here)
cp -n .env.example .env 2>/dev/null || true
for kv in 'ELASTIC_PASSWORD=ChangeMe_ElasticPassword' 'KIBANA_SYSTEM_PASSWORD=ChangeMe_KibanaSystemPassword' 'APM_SECRET_TOKEN=ChangeMe_ApmSecretToken'; do
  k="${kv%%=*}"; sed -i "/^${k}=/d" .env; echo "$kv" >> .env
done
chmod 600 .env

# 9. verify the three services
for s in elasticsearch kibana apm-server; do printf '%-14s: %s\n' "$s" "$(systemctl is-active $s)"; done
curl -s -o /dev/null -w 'apm-server http=%{http_code}\n' http://localhost:8200/                 # -> 200
curl -s -u 'elastic:ChangeMe_ElasticPassword' http://localhost:9200/_cluster/health?pretty | grep '"status"'
```

## Test

The shared contract test sends a real APM intake event (a transaction with a unique `service.name`) to
`:8200`, verifies it lands in the Elasticsearch `traces-apm-*` data stream, checks Kibana is available,
then **deletes the test docs and proves zero residue**.

### A. Scripted test (the shared contract test)

```bash
# from utility/07_Elastic_APM/  (auto-reads the host + secrets from 01_native_single/.env)
bash ../test.sh 01_native_single

# cross-host (test client ≠ this host) — paste the creds setup.sh printed:
APM_HOST=<host> APM_SECRET_TOKEN=<token> ELASTIC_PASSWORD=<pw> bash ../test.sh
```

Exits `0` and prints `RESULT: PASS` when the trace ingests, indexes, and is then deleted with zero residue.

### B. Manual test (raw write → read → clean-up)

```bash
# pull the secrets from .env (step 8 of the Manual install saved them there)
set -a; . ./.env; set +a
SVC="dokandar_apmtest_$(date +%s)"; TID=$(head -c8 /dev/urandom|od -An -tx1|tr -d ' \n')
TRACE=$(head -c16 /dev/urandom|od -An -tx1|tr -d ' \n'); TSU="$(date +%s)000000"

# 1. WRITE — send an APM intake event (the transaction name carries the UTF-8 round-trip 'চাল')
printf '{"metadata":{"service":{"name":"%s","agent":{"name":"go","version":"2.0.0"},"language":{"name":"go"}}}}\n{"transaction":{"id":"%s","trace_id":"%s","type":"request","name":"GET /চাল-dokandar","duration":1.5,"timestamp":%s,"sampled":true,"span_count":{"started":0}}}\n' \
  "$SVC" "$TID" "$TRACE" "$TSU" \
  | curl -s -o /dev/null -w 'intake http=%{http_code}\n' -H "Authorization: Bearer ${APM_SECRET_TOKEN}" \
      -H 'Content-Type: application/x-ndjson' --data-binary @- http://localhost:8200/intake/v2/events   # -> 202

# 2. READ — confirm the trace landed in Elasticsearch (poll the async index)
sleep 3
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' \
  "http://localhost:9200/traces-apm*/_count?ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"        # -> "count":1

# 3. CLEAN-UP — delete the test docs and prove zero residue
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' -X POST \
  "http://localhost:9200/traces-apm*/_delete_by_query?refresh=true&ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"
curl -s -u "elastic:${ELASTIC_PASSWORD}" -H 'content-type: application/json' \
  "http://localhost:9200/traces-apm*/_count?ignore_unavailable=true" \
  -d "{\"query\":{\"term\":{\"service.name\":\"${SVC}\"}}}"        # -> "count":0  (zero residue)
```

## Status / logs

```bash
sudo bash setup.sh status        # the three service states + data-dir size
# manual equivalents:
for s in elasticsearch kibana apm-server; do printf '%-14s: %s\n' "$s" "$(systemctl is-active $s)"; done
sudo journalctl -u apm-server -n 50 --no-pager
```

## Uninstall

### A. Scripted uninstall

Removes the three packages and config/logs but **keeps the data** at `/data/apm_stack`:

```bash
sudo bash setup.sh uninstall     # packages + config/logs removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/apm_stack (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + drop the ES data symlink (keeps the data on /data)
sudo systemctl stop apm-server kibana elasticsearch
sudo rm -f /var/lib/elasticsearch        # this is the symlink, not the data

# purge the packages + config/logs (data on /data is NOT touched)
sudo apt-get purge -y apm-server kibana elasticsearch
sudo apt-get autoremove --purge -y
sudo rm -rf /etc/elasticsearch /etc/kibana /etc/apm-server /var/log/elasticsearch /var/log/kibana /var/log/apm-server
sudo rm -f /etc/apt/sources.list.d/elastic-9.x.list /etc/sysctl.d/99-dokandar-apm.conf
sudo apt-get update -y

# full wipe — ALSO delete the data (irreversible)
sudo rm -rf /data/apm_stack
```

## Notes

- Three JVM/Node services on one host — keep `ES_JAVA_HEAP` small (default `512m`). Kibana also needs RAM.
- ES runs security ON with **plain HTTP** (HTTP TLS explicitly off) so agents/clients use basic auth over
  the private/SG-fenced network; for production, enable HTTP TLS and front Kibana with the nginx/Caddy edge.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../03_docker_single/` and `../04_docker_cluster/` — the Docker Compose variants.
- `../../../dependencies/03_Databases_datastores/06_Elasticsearch_9.4/`,
  `../../../dependencies/07_Observability/05_Elastic_APM_Server_9.4/`,
  `../../../dependencies/07_Observability/06_Kibana_9.4/` — the original per-component install scripts +
  the canonical manual-install references these commands mirror.
</content>
</invoke>
