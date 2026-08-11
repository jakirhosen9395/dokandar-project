# Elastic APM 9.4 — utility dependency (integrated ES + APM Server + Kibana)

Elastic APM is DOKANDAR's distributed-tracing tier: every service wires an APM agent **outermost**, and the
traces land in Elasticsearch and are explored in the **Kibana APM app**. So this is not just the ingest
server — each variant is the **integrated stack**: **Elasticsearch** (storage) + **APM Server** (agent
ingest on `:8200`) + **Kibana** (the APM app UI on `:5601`), wired together.

## Layout

```text
07_Elastic_APM/
├── README.md            ← this file
├── test.sh              ← shared contract test (curl) — sends an APM event, verifies it reaches ES
├── 01_native_single/    ← native: ES + APM Server + Kibana (systemd), data in /data/apm_stack   [TESTED]
├── 03_docker_single/    ← Docker Compose: ES + APM Server + Kibana                               [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: ES + 2 stateless APM Server replicas + Kibana       [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised cluster covers HA.)

> **Why the cluster is "stateless replicas".** APM Server is a **stateless ingest proxy** — it holds no
> data, it just validates agent payloads and writes them to Elasticsearch. So its HA story is **horizontal
> replicas** (2+ apm-server instances writing to the same ES), not a stateful cluster. The deps layer has
> no `cluster_mode` for APM for this reason. The `04_docker_cluster` variant runs **2 apm-server replicas**
> with Kibana over Elasticsearch; for a fully HA backend, point them at the 3-node ES cluster
> (`../03_Elasticsearch/04_docker_cluster`).

Security is ON: ES uses the `elastic` superuser (auto-generated password); Kibana connects as the
`kibana_system` service user (auto-generated password); APM agents authenticate with an auto-generated
**secret token**. All saved to that variant's `.env` (chmod 600).

## The shared test script — `test.sh`

Uses **`curl`** to exercise the full pipeline: it sends a real **APM intake event** (a transaction with a
unique `service.name`) to APM Server `:8200` (Bearer secret token), polls Elasticsearch until the trace
appears in the `traces-apm-*` data stream, checks **Kibana** reports `available`, then **deletes** the test
traces and **proves zero residue**.

### How to run it

```bash
bash test.sh 03_docker_single     # reads the variant's .env (host, ports, token, ES password)
# or against ANY stack (e.g. cross-host) — pass the host + secrets via env:
APM_HOST=<host> APM_SECRET_TOKEN=<token> ELASTIC_PASSWORD=<pw> bash test.sh
```

### Reading the result

`RESULT: PASS — APM pipeline OK, test traces deleted, zero residue.` and exit `0` means an agent event
flowed agent → APM Server → Elasticsearch and Kibana is up. Any failure prints the failing checks.

## See also

- `../README.md` — the utility-dependency overview.
- `../03_Elasticsearch/` — the standalone Elasticsearch utility (the same ES this stack stores into).
- `../../dependencies/07_Observability/05_Elastic_APM_Server_9.4/` — the original APM Server install scripts.
