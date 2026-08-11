# Elasticsearch 9.4 — Docker Compose HA cluster (3 nodes)

A 3-node Elasticsearch cluster via Docker Compose — **es01 / es02 / es03, any node read-write** — with
**security ON**, **transport TLS** between nodes (mandatory for multi-node security), and HTTP basic auth
over plain HTTP. Each node's data is on its own **host bind mount** (survives `docker compose down -v`).
Tested on Ubuntu 26.04.

```text
                 reads + writes on ANY node (ES routes internally)
        ┌──────────────────┬──────────────────┬──────────────────┐
        ▼                  ▼                  ▼
 ┌────────────┐    ┌────────────┐    ┌────────────┐
 │   es01     │◄──►│   es02     │◄──►│   es03     │   transport TLS (shared PKCS12 cert)
 │ :9200 RW   │    │ :9201 RW   │    │ :9202 RW   │   discovery.seed_hosts=es01,es02,es03
 └────────────┘    └────────────┘    └────────────┘
```

Unlike a single-primary store there is **no fixed write node** — every node accepts reads and writes and
Elasticsearch routes shards internally. Cluster formation is **automatic on `up`** (the nodes discover each
other by service name via `discovery.seed_hosts` + `cluster.initial_master_nodes`) — there is **no manual
cluster-init step**.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(auto-generates the elastic password + the shared transport-TLS cert, waits for all 3 nodes healthy,
verifies/rotates the password, prints a credentials summary); and **B. Manual** — raw `docker compose` +
Ubuntu commands.

## Topology

| Node | Container | Host port | Role |
| --- | --- | --- | --- |
| `es01` | `dokandar_es01` | `9200` | master-eligible / data (read-write) |
| `es02` | `dokandar_es02` | `9201` | master-eligible / data (read-write) |
| `es03` | `dokandar_es03` | `9202` | master-eligible / data (read-write) |

`node.name` defaults to each container's hostname (`es01`/`es02`/`es03`), matching
`cluster.initial_master_nodes`.

## Transport TLS (the keyFile-equivalent)

Multi-node security **requires** transport TLS. `setup.sh` generates a shared **PKCS12** keystore once
(via `elasticsearch-certutil`, empty password, DNS SANs `es01,es02,es03`) at `CERTS_HOST_PATH`
(`${DATA_ROOT}/es_cluster/certs/node.p12`) and bind-mounts it **read-only** into all three nodes
(`verification_mode=certificate`). This is the internal-auth secret. The HTTP layer stays plain (basic
auth) so clients need no CA.

## Prerequisites — install Docker (one time)

Docker Engine + the Compose plugin (see `../03_docker_single/README.md` for the full install). The shared
`test.sh` and the acceptance check use `curl` (already on virtually every box) — no Elasticsearch client to
install.

## Configure

```bash
cp .env.example .env        # set host ports if 9200–9202 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `ES_IMAGE_TAG` (`9.4.2`),
`ES_CLUSTER_NAME`, `ELASTIC_PASSWORD`, `ES_JAVA_HEAP` (`512m`, **per node** — 3 JVMs on one box),
`ES_PORT1`/`ES_PORT2`/`ES_PORT3` (host ports → each container's `9200`), `CERTS_HOST_PATH`, `DATA_ROOT`.
**If `9200`–`9202` are taken on this host** (e.g. a native or single-node ES is already running), change all
three. **Leave `ELASTIC_PASSWORD` empty to auto-generate a complex password** — `setup.sh up` fills it
**and generates the shared cert** before `docker compose up`. **A direct `docker compose up` needs
`ELASTIC_PASSWORD` set non-empty in `.env` AND the cert already generated** (the compose file marks both
required with `:?`), so the manual path does both explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up                  # auto-generates the elastic password + the transport cert
bash setup.sh up --password 'MyOwnSecret'   # or set the password explicitly
bash setup.sh up --gen-password   # rotate ONLY the elastic password (cert is generated once)
```

`setup.sh up` prints **numbered step output** (1/5 … 5/5): raises `vm.max_map_count`, generates the
**PKCS12 transport cert** + per-node data dirs (chown uid 1000), brings up all three nodes, waits for **3
healthy**, verifies/rotates the `elastic` password, then prints cluster state + a **credentials summary**
(all three node endpoints, user, password, cert path, connection URL). Passwords are shown once and saved
to `.env`; a no-flag re-run reuses them.

> **Password rotation.** `--gen-password` rotates **only the elastic password** (a safe live operation via
> the `_password` API). The **transport cert is generated once** (first `up`, when absent) and **never
> rotated** here — rotating it would break inter-node TLS on the running cluster. To change it, `purge` and
> re-create.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose requires a non-empty ELASTIC_PASSWORD via :?)
cp .env.example .env
sed -i "s/^ELASTIC_PASSWORD=.*/ELASTIC_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. host prereq
sudo sysctl -w vm.max_map_count=262144

# 3. generate the SHARED transport-TLS cert ONCE (CA + a node keystore, PKCS12, empty password, DNS SANs
#    es01,es02,es03) into CERTS_HOST_PATH — this is exactly what setup.sh's ensure_certs does
sudo mkdir -p /data/es_cluster/certs
sudo docker run --rm --user 0 -v /data/es_cluster/certs:/certs \
  docker.elastic.co/elasticsearch/elasticsearch:9.4.2 bash -c '
    set -e; cd /usr/share/elasticsearch
    bin/elasticsearch-certutil ca --silent --out /certs/ca.p12 --pass ""
    bin/elasticsearch-certutil cert --silent --ca /certs/ca.p12 --ca-pass "" \
      --dns es01,es02,es03 --name node --out /certs/node.p12 --pass ""
    chown -R 1000:1000 /certs; chmod 644 /certs/*.p12'

# 4. per-node data dirs, all owned by the image's uid 1000 (the elasticsearch user)
sudo mkdir -p /data/es_cluster/es01 /data/es_cluster/es02 /data/es_cluster/es03
sudo chown -R 1000:1000 /data/es_cluster

# 5. bring up all three nodes — they discover each other and form the cluster automatically (no init step)
docker compose up -d

# 6. wait until all three report healthy (first form takes ~40s), then check the node list
watch -n2 'docker compose ps'      # Ctrl-C once dokandar_es01/es02/es03 are all "healthy"
docker compose exec es01 \
  curl -s -u elastic:ChangeMe_StrongPassword "http://localhost:9200/_cat/nodes?h=name,master"   # -> es01/es02/es03
```

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh acceptance
```

Runs the 3 criteria: **cluster health is green/yellow with 3 nodes**, a doc written on **es01** (with
`replicas=2`) is **read back from es03** (replication), and the **node count == 3**. Cleans up the
`ha_check` index after itself.

### B. Manual acceptance (write on es01 → read on es03 → assert replication)

```bash
PW=ChangeMe_StrongPassword
# (1) cluster health: 3 nodes, green/yellow
docker compose exec es01 curl -s -u elastic:$PW "http://localhost:9200/_cluster/health?filter_path=status,number_of_nodes"

# (2) create an index replicated to all nodes, write a doc on es01
docker compose exec es01 curl -s -u elastic:$PW -X PUT "http://localhost:9200/ha_check?wait_for_active_shards=all" \
  -H 'Content-Type: application/json' -d '{"settings":{"number_of_replicas":2}}'
docker compose exec es01 curl -s -u elastic:$PW -X POST "http://localhost:9200/ha_check/_doc/1?refresh=wait_for" \
  -H 'Content-Type: application/json' -d '{"note":"replicated-চাল"}'

# read it back from es03 (proves replication across the cluster)
docker compose exec es03 curl -s -u elastic:$PW "http://localhost:9200/ha_check/_doc/1?filter_path=_source.note"   # -> {"_source":{"note":"replicated-চাল"}}

# clean up
docker compose exec es01 curl -s -u elastic:$PW -X DELETE "http://localhost:9200/ha_check" >/dev/null
```

## Test (the shared contract test, against a node)

### A. Scripted test

```bash
# from utility/03_Elasticsearch/  (reads this .env; ES_PORT1 = es01)
bash test.sh 04_docker_cluster

# or any node explicitly
bash test.sh "http://elastic:<your-password>@127.0.0.1:9201"
```

Creates a throwaway `dokandar_estest_<ts>` index on the node, exercises the full contract, then deletes it
and proves zero residue.

### B. Manual test (raw write → read → clean-up)

```bash
PW=ChangeMe_StrongPassword; IDX=dokandar_smoke
docker compose exec es01 curl -s -u elastic:$PW -X POST "http://localhost:9200/$IDX/_doc/1?refresh=wait_for" \
  -H 'Content-Type: application/json' -d '{"name_bn":"চাল","name_en":"rice"}'
docker compose exec es01 curl -s -u elastic:$PW "http://localhost:9200/$IDX/_doc/1?filter_path=_source.name_bn"   # -> {"_source":{"name_bn":"চাল"}}
docker compose exec es01 curl -s -u elastic:$PW -X DELETE "http://localhost:9200/$IDX" >/dev/null
docker compose exec es01 curl -s -o /dev/null -w '%{http_code}\n' -u elastic:$PW "http://localhost:9200/$IDX"     # -> 404
```

## Connection model

- **Reads + writes → any node** (`127.0.0.1:9200` / `:9201` / `:9202`). Elasticsearch routes internally;
  there is no fixed write node. A client can list all three hosts and let the driver round-robin.
- Losing one node keeps the cluster available (the other two retain quorum); shards with `replicas>=1`
  stay readable.

## Data persistence

Per-node data are **host bind mounts** under `${DATA_ROOT}/es_cluster/{es01,es02,es03}` (the shared cert
lives under the same root at `es_cluster/certs`), so:

```bash
bash setup.sh down        # remove the 3 containers — DATA + certs PRESERVED
docker compose down -v    # even with -v — bind mounts survive
bash setup.sh up          # the cluster re-forms with its data intact
bash setup.sh purge       # the ONLY command that deletes the data + certs
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + host data size
bash setup.sh logs          # follow all 3 nodes' logs
# manual equivalents:
docker compose ps
docker compose logs --tail=100 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data + certs PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/es_cluster (full wipe, incl. certs)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data + certs are PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the per-node data dirs AND the shared cert (irreversible)
docker compose down -v
sudo rm -rf /data/es_cluster
```

## Notes

- **Browser UI:** none (Kibana is a separate companion — point its `elasticsearch.hosts` at a node and
  browse it on `:5601`).
- Heap is **per node** (`ES_JAVA_HEAP`, 512m) — three JVMs on one box, so keep it small.

## See also

- `../README.md` — using `test.sh` across all variants.
- `../03_docker_single/` — the single-node Docker variant (and the Docker install prerequisites).
- `../../../dependencies/03_Databases_datastores/06_Elasticsearch_9.4/cluster_mode/run_book.md` — the native
  (no-Docker) HA run book this mirrors (TLS on transport + HTTP).
