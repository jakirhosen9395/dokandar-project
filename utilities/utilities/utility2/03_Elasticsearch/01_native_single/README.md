# Elasticsearch 9.4 — native single-node (no Docker)

A single Elasticsearch node from Elastic's **9.x apt repo**, managed by **systemd**, configured by an
**env file**, data under **`/data/elasticsearch`** (symlinked from `/var/lib/elasticsearch`, preserved on
uninstall). Security is ON (the built-in `elastic` superuser) with **HTTP basic auth over plain HTTP**
(single-node → transport TLS off, http TLS off — no cert hassle for clients).

- **What runs:** the `elasticsearch` package (pinned `9.4.*`), one JVM daemon under systemd.
- **Data:** `${DATA_ROOT}/elasticsearch` (default `/data/elasticsearch`), symlinked from
  `/var/lib/elasticsearch`. Install is **non-destructive** (existing data is copied/reused, never wiped);
  uninstall **keeps the data**.
- **Browser UI:** none here — **Kibana** is the companion UI (a separate deploy).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (auto-generates a complex password, prints a credentials summary); and **B. Manual** — raw
copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both produce the same node.

## Configure

```bash
cp .env.example .env        # optional — edit port / bind address / a fixed password
```

`.env` is gitignored (it holds the real password); only `.env.example` is committed. Key vars:
`ES_VERSION` (`9.4`), `ELASTIC_PASSWORD`, `ES_NETWORK_HOST` (default `0.0.0.0`), `ES_HTTP_PORT` (`9200`),
`ES_CLUSTER_NAME` (`dokandar`), `ES_JAVA_HEAP` (`512m`), `DATA_ROOT` (`/data`). **Leave `ELASTIC_PASSWORD`
empty to auto-generate a complex (24-char) password on install** — it is shown once and saved back to
`.env`. With the script you can skip the edit entirely; with the manual path you choose the password
yourself in the commands below. `--user`/`--db` do **not** apply (Elasticsearch has a fixed `elastic`
superuser and creates indices on demand).

## Install

### A. Scripted install (recommended)

```bash
cp .env.example .env
sudo bash setup.sh install                 # auto-generates a complex password
sudo bash setup.sh install --password 'MyOwnSecret'   # or set the password explicitly
sudo bash setup.sh install --gen-password  # force a fresh generated password (rotate)
```

Prints **numbered step output** (1/6 … 6/6 with ✓ ticks) and ends with a **credentials summary** — REST
endpoint, cluster name, user (`elastic`), password, connection URL, and a `curl` health command. The
password is **shown once** and persisted to `.env` (chmod 600). Idempotent: raises `vm.max_map_count`,
prepares `/data/elasticsearch` (preserving any existing data), installs the pinned package, writes the
managed config, starts the node, sets the `elastic` password, and verifies an authenticated request. A
no-flag re-run reuses the stored password. Password resolution: `--password` > a non-empty
`ELASTIC_PASSWORD` in `.env` > auto-generated.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
password where shown. **Do the `/var/lib/elasticsearch` → `/data` symlink *before* `apt install`**, or the
node initialises its data on the root disk instead of `/data`.

```bash
# 1. raise vm.max_map_count (required by ES) and persist it
sudo sysctl -w vm.max_map_count=262144
echo 'vm.max_map_count=262144' | sudo tee /etc/sysctl.d/99-dokandar-elasticsearch.conf

# 2. point the data dir at /data BEFORE installing (so the node lands on /data) — non-destructive
sudo mkdir -p /data/elasticsearch
sudo rm -rf /var/lib/elasticsearch && sudo ln -sfn /data/elasticsearch /var/lib/elasticsearch

# 3. trust Elastic's signing key + add the 9.x apt repo, then install the pinned package
sudo apt-get update -y
sudo apt-get install -y wget gnupg curl ca-certificates apt-transport-https
sudo install -d -m 0755 /etc/apt/keyrings
wget -qO- https://artifacts.elastic.co/GPG-KEY-elasticsearch | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/elastic.gpg
echo "deb [signed-by=/etc/apt/keyrings/elastic.gpg] https://artifacts.elastic.co/packages/9.x/apt stable main" | sudo tee /etc/apt/sources.list.d/elastic-9.x.list
sudo apt-get update -y
sudo apt-get install -y elasticsearch=9.4.*

# 4. own the data dir + set the JVM heap (512m here; <= ~50% RAM and <= 31g)
sudo chown -R elasticsearch:elasticsearch /data/elasticsearch
sudo mkdir -p /etc/elasticsearch/jvm.options.d
printf -- '-Xms512m\n-Xmx512m\n' | sudo tee /etc/elasticsearch/jvm.options.d/heap.options

# 5. remove the deb's auto-generated TLS security block (it requires certs/TLS and conflicts with our
#    flat keys), then write our managed block: security ON, HTTP + transport TLS OFF (plain basic auth)
sudo sed -i '/BEGIN SECURITY AUTO CONFIGURATION/,/END SECURITY AUTO CONFIGURATION/d' /etc/elasticsearch/elasticsearch.yml
sudo tee -a /etc/elasticsearch/elasticsearch.yml >/dev/null <<'YAML'
# >>> dokandar managed >>>
cluster.name: dokandar
network.host: 0.0.0.0
http.port: 9200
discovery.type: single-node
xpack.security.enabled: true
xpack.security.http.ssl.enabled: false
xpack.security.transport.ssl.enabled: false
# <<< dokandar managed <<<
YAML

# 6. start the node, then set the 'elastic' password (bootstrap to an auto pw, set ours via the REST API)
sudo systemctl daemon-reload
sudo systemctl enable --now elasticsearch
until curl -s --max-time 3 http://localhost:9200 >/dev/null 2>&1; do sleep 3; done
BOOT="$(sudo /usr/share/elasticsearch/bin/elasticsearch-reset-password -u elastic -a -b -s | tr -d '[:space:]')"
curl -s -u "elastic:$BOOT" -X POST http://localhost:9200/_security/user/elastic/_password \
  -H 'Content-Type: application/json' -d '{"password":"ChangeMe_StrongPassword"}'

# 7. verify
systemctl is-active elasticsearch                                              # -> active
curl -s -u elastic:ChangeMe_StrongPassword http://localhost:9200/_cluster/health?pretty | grep '"status"'  # -> green
```

> `ES_NETWORK_HOST` defaults to `0.0.0.0` so a remote client can reach it (auth is always required); set
> `network.host: 127.0.0.1` above to restrict to loopback.

## Test

The contract/smoke test creates a throwaway `dokandar_estest_<ts>` index, exercises mapping/bulk/UTF-8/
search/aggregation/update, then **deletes the index and proves zero residue**.

### A. Scripted test (the shared contract test)

```bash
# from utility/03_Elasticsearch/  (auto-reads elastic + the generated password from 01_native_single/.env)
bash test.sh 01_native_single

# or pass the connection explicitly (use your actual password)
bash test.sh "http://elastic:<your-password>@127.0.0.1:9200"
```

Exits `0` and prints `RESULT: PASS — test index deleted, zero residue.` when every check passes.

### B. Manual test (raw write → read → clean-up)

```bash
PW='<your-password>'; IDX=dokandar_smoke
# write a bilingual UTF-8 doc, refresh immediately
curl -s -u elastic:$PW -X POST "http://127.0.0.1:9200/$IDX/_doc/1?refresh=wait_for" \
  -H 'Content-Type: application/json' -d '{"name_bn":"চাল","name_en":"rice"}'
# read it back (proves the UTF-8 round-trip)
curl -s -u elastic:$PW "http://127.0.0.1:9200/$IDX/_doc/1?filter_path=_source.name_bn"   # -> {"_source":{"name_bn":"চাল"}}
# delete the index (zero residue) and confirm it is gone
curl -s -u elastic:$PW -X DELETE "http://127.0.0.1:9200/$IDX" >/dev/null
curl -s -o /dev/null -w '%{http_code}\n' -u elastic:$PW "http://127.0.0.1:9200/$IDX"      # -> 404
```

## Status

```bash
sudo bash setup.sh status        # service + cluster health + user + data-dir size
# manual equivalent:
systemctl is-active elasticsearch
curl -s -u elastic:<your-password> http://localhost:9200/_cluster/health?pretty | grep '"status"'
```

## Uninstall

### A. Scripted uninstall

Removes the package, config, logs, repo files and sysctl drop-in but **keeps the data** at
`/data/elasticsearch`:

```bash
sudo bash setup.sh uninstall     # package + config/logs/repo removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/elasticsearch (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + drop the data symlink (keeps the data on /data)
sudo systemctl stop elasticsearch
sudo rm -f /var/lib/elasticsearch        # this is the symlink, not the data

# purge the package + config/logs + repo + sysctl drop-in (data on /data is NOT touched)
sudo apt-get purge -y elasticsearch
sudo apt-get autoremove --purge -y
sudo rm -rf /etc/elasticsearch /var/log/elasticsearch
sudo rm -f /etc/apt/sources.list.d/elastic-9.x.list /etc/apt/keyrings/elastic.gpg /etc/sysctl.d/99-dokandar-elasticsearch.conf
sudo apt-get update -y

# full wipe — ALSO delete the data (irreversible)
sudo rm -rf /data/elasticsearch
```

## Notes

- **Browser UI:** none here — **Kibana** is the companion UI (a separate deploy that points its
  `elasticsearch.hosts` at this node's REST endpoint, browsed on `:5601`).
- **Heap** is `ES_JAVA_HEAP` (512m default); keep it `<= ~50%` RAM and `<= 31g`.

## See also

- `../README.md` — the utility-dependency overview and how to use `test.sh` across all variants.
- `../03_docker_single/` — the Docker single-node variant.
- `../../../dependencies/03_Databases_datastores/06_Elasticsearch_9.4/` — the original install scripts + the
  canonical manual-install reference these commands mirror, plus the `cluster_mode/run_book.md` native HA
  reference (TLS on transport + HTTP).
