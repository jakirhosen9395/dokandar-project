# Prometheus 3.12 — Docker Compose, HA cluster (2 replicas + Thanos Querier)

Prometheus HA the standard way: **two identical replicas** (`prom-a`, `prom-b`) scraping the same targets,
a **Thanos sidecar** exposing each replica's data over gRPC, and a **Thanos Querier** (`:10902`) that fans
out to both and **deduplicates** by the `replica` external label — so a replica failure is invisible at
query time. **Query the Thanos Querier**, not the individual replicas. Per-replica TSDB is on a **host bind
mount** (survives `down -v`). No built-in auth. Tested on Ubuntu 26.04.

```text
        scrape (both replicas scrape the SAME targets)
          │
   ┌──────┴───────┐
   ▼              ▼
┌────────┐    ┌────────┐        ┌───────────┐        ┌──────────────────┐
│ prom-a │    │ prom-b │        │ sidecar-a │ gRPC   │  Thanos Querier  │
│ :9090  │    │ :9092  │ ─────► │ sidecar-b │ ─────► │  :10902 (dedup)  │  ◄── queries / UI
│ rep=a  │    │ rep=b  │        │  StoreAPI │        │  replica-label   │
└────────┘    └────────┘        └───────────┘        └──────────────────┘
```

The Querier deduplicates the two replicas' identical series by the `replica` external label, so losing
one replica is invisible at query time. **There is no replica-of / leader election — the two Prometheus
replicas are fully independent**; HA = "scrape twice, dedupe at query".

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(creates the per-replica data dirs, brings up all five containers, waits for both replicas + the Querier
healthy, reports the store count, prints a connection summary); and **B. Manual** — raw `docker compose` +
Ubuntu commands. Both produce the same cluster.

## Topology

| Service | Container | Host port | Role |
| --- | --- | --- | --- |
| prom-a | `dokandar_prom_a` | `9090` | Prometheus replica (`external_labels: replica=a`) |
| prom-b | `dokandar_prom_b` | `9092` | Prometheus replica (`external_labels: replica=b`) |
| sidecar-a / sidecar-b | `dokandar_thanos_sidecar_a/b` | — | Thanos StoreAPI (gRPC `:10901`) over each replica |
| querier | `dokandar_thanos_querier` | `10902` | unified, **deduplicated** query API + UI |

## How it works (and why the data survives `down -v`)

- Each replica stores its TSDB on a **host bind mount** at the container's `/prometheus` path:
  `${DATA_ROOT}/prometheus_cluster/{a,b}`. There is **no named volume**, so `docker compose down -v` keeps
  both replicas' data and they resume scraping on `up`.
- Each replica mounts its own committed scrape config (`./prometheus-a.yml` / `./prometheus-b.yml`) — they
  are identical except for `external_labels.replica` (`a` vs `b`), which is the label the Querier collapses.
- A **Thanos sidecar** per replica exposes that replica's data over gRPC (StoreAPI). The **Thanos Querier**
  is wired to both sidecars (`--endpoint=sidecar-a:10901 --endpoint=sidecar-b:10901`) with
  `--query.replica-label=replica`. **The whole cluster comes up with one `docker compose up` — there is no
  manual cluster-init / replication step.**

## Prerequisites

Docker Engine + Compose plugin (see `../03_docker_single/README.md` for the install). The tests only need
`curl` on the host (already present on Ubuntu); it can fall back to a `curlimages/curl` container.

## Configure

```bash
cp .env.example .env        # set host ports if 9090/9092/10902 are taken; image tags / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `PROM_VERSION` (`3.12.0`),
`THANOS_VERSION` (`0.41.0`), `PROM_A_PORT` (`9090`) / `PROM_B_PORT` (`9092`) / `THANOS_PORT` (`10902`),
`PROMETHEUS_RETENTION` (`15d`), `DATA_ROOT` (`/data`). **Prometheus and Thanos have no auth, so there are
no secrets to set** — a direct `docker compose up` needs nothing in `.env` beyond the ports. If a native or
single-node Prometheus already holds these ports, change them all.

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3), creates the per-replica data dirs
(`${DATA_ROOT}/prometheus_cluster/{a,b}`) and `chown`s them to `nobody` (uid `65534`), runs
`docker compose up -d` for all five containers, waits for both replicas **and** the Querier to answer
`/-/healthy`, reports how many **stores** the Querier sees (expect **2**), and ends with a **connection
summary** (Thanos Querier URL — use this — plus the two raw replica URLs and the host data dirs). The
browser UI is the **Thanos query UI** at `http://<host>:10902`.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file (no secret needed — Prometheus/Thanos have no auth)
cp .env.example .env

# 2. create the per-replica host bind-mount data dirs and chown them to 'nobody' (uid 65534)
sudo mkdir -p /data/prometheus_cluster/a /data/prometheus_cluster/b
sudo chown -R 65534:65534 /data/prometheus_cluster

# 3. bring up the whole cluster (2 prometheus + 2 sidecars + 1 querier) — no manual init step
docker compose up -d

# 4. wait until both replicas + the querier answer /-/healthy
for u in 9090/-/healthy 9092/-/healthy 10902/-/healthy; do \
  curl -fsS -o /dev/null -w "$u -> %{http_code}\n" "http://127.0.0.1:${u}"; done   # -> 200 each

# 5. verify the Querier sees BOTH replica stores (expect 2)
curl -fsS http://127.0.0.1:10902/api/v1/stores | grep -oE ':10901"' | wc -l        # -> 2
```

**Browser UI:** open the **Thanos query UI** at `http://<host>:10902/` (no login — no built-in auth). It
serves the deduplicated, Prometheus-compatible query API across both replicas.

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh acceptance
```

Runs three checks: **(1)** both Prometheus replicas answer `/-/healthy`; **(2)** the Thanos Querier sees
**2 stores**; **(3)** the Querier **deduplicates** the two replicas — with `dedup=true` the `replica`
label is collapsed (0 replica-labelled series), with `dedup=false` both replicas' series are visible
(>0). Read-only; nothing to clean up.

### B. Manual acceptance (both replicas up → Querier dedups → replica failure is invisible)

```bash
# 1. both replicas are healthy
curl -fsS -o /dev/null -w 'replica-a=%{http_code}\n' http://127.0.0.1:9090/-/healthy   # -> 200
curl -fsS -o /dev/null -w 'replica-b=%{http_code}\n' http://127.0.0.1:9092/-/healthy   # -> 200

# 2. the Querier sees BOTH sidecar stores
curl -fsS http://127.0.0.1:10902/api/v1/stores | grep -oE ':10901"' | wc -l            # -> 2

# 3. dedup collapses the replica label: dedup=true has 0 replica-labelled 'up' series,
#    dedup=false has both (>0). (Allow ~1 scrape interval after 'up' for series to appear.)
echo "dedup=true  -> $(curl -fsS 'http://127.0.0.1:10902/api/v1/query?query=up&dedup=true'  | grep -oE '"replica":"[ab]"' | wc -l)"   # -> 0
echo "dedup=false -> $(curl -fsS 'http://127.0.0.1:10902/api/v1/query?query=up&dedup=false' | grep -oE '"replica":"[ab]"' | wc -l)"   # -> >0

# 4. kill one replica — the Querier still answers (HA): a row read on the cluster is still served
docker compose stop prom-b
curl -fsS 'http://127.0.0.1:10902/api/v1/query?query=up&dedup=true' | grep -o '"status":"success"'   # -> "status":"success"
docker compose start prom-b      # restore the replica
```

## Test (the shared contract test, against the Querier)

### A. Scripted test

```bash
# from utility/08_Prometheus/  (point at the Thanos Querier — the Prometheus-compatible query API)
bash ../test.sh 04_docker_cluster
bash ../test.sh "http://<host>:10902"   # cross-host
```

> The shared `test.sh` resolves `04_docker_cluster` to the variant `.env`; if it lands on a replica port
> instead of `THANOS_PORT`, pass the Querier URL explicitly as shown.

### B. Manual test (raw write → read → clean-up against the Querier)

Prometheus is pull-based (no write API), so the round-trip is exercised through the **self/HA-scrape**: the
replicas write `up` samples into their bind-mounted TSDBs and the Querier reads them back, deduplicated —
leaving zero residue by construction.

```bash
# healthy + ready on the Querier (Prometheus-compatible API)
curl -fsS -o /dev/null -w 'healthy=%{http_code}\n' http://127.0.0.1:10902/-/healthy   # -> healthy=200
curl -fsS -o /dev/null -w 'ready=%{http_code}\n'   http://127.0.0.1:10902/-/ready     # -> ready=200

# write→read round-trip: the deduplicated 'up' series reads back as 1
curl -fsS 'http://127.0.0.1:10902/api/v1/query?query=up&dedup=true' | head -c 300; echo
# -> {"status":"success",...,"value":[<ts>,"1"]...}

# UTF-8 'চাল' round-trips through PromQL unchanged (read-only, nothing stored)
curl -fsSG 'http://127.0.0.1:10902/api/v1/query' --data-urlencode 'query=label_replace(up,"note","চাল","","")' \
  | grep -o '"note":"চাল"' | head -1                                                   # -> "note":"চাল"
```

## Connection model

- **Query / UI → the Thanos Querier** (`127.0.0.1:10902`). It is the unified, deduplicated endpoint — use
  it for all queries, dashboards (Grafana), and the test.
- The raw replicas (`:9090` / `:9092`) are for debugging a single replica only; they are **not**
  deduplicated and either one alone is a single point of failure.

## Failover

There is no promotion step — both replicas are equal and independent. If one replica dies, the Querier
keeps serving from the survivor (the `replica` dedup makes it invisible); restart the dead replica and it
resumes scraping from its retained TSDB:

```bash
docker compose stop prom-a                 # simulate a replica loss
curl -fsS 'http://127.0.0.1:10902/api/v1/query?query=up&dedup=true' | grep -o '"status":"success"'   # still served
docker compose start prom-a                # it resumes from its bind-mounted TSDB — no re-clone
```

## Status / logs

```bash
bash setup.sh status        # compose ps + host data size
bash setup.sh logs          # follow all container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=100 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 5 containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/prometheus_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mounts survive -v

# full wipe — ALSO delete the per-replica host data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/prometheus_cluster
```

## See also

- `../README.md` — the Prometheus utility overview + how to use `test.sh` across all variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../03_docker_single/` — the single-container Docker variant.
- `../../../dependencies/07_Observability/02_Prometheus_3.12/cluster_mode/run_book.md` — the native
  (no-Docker) two-replica + Thanos HA reference this mirrors.
