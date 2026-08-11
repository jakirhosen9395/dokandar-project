# Prometheus 3.12 — utility dependency

Prometheus is DOKANDAR's metrics pull-stack: every service exposes `/metrics` (RED metrics + an
`<svc>_outbox_pending` gauge) and Prometheus scrapes them. Built-in expression-browser UI + HTTP API on
`:9090`. This folder holds the install variants plus a **shared test script** for all of them.

## Layout

```text
08_Prometheus/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (curl + HTTP API) — works against ALL variants
├── 01_native_single/    ← native (no Docker), official binary + systemd, data in /data/prometheus  [TESTED]
├── 03_docker_single/    ← Docker Compose (prom/prometheus), bind-mounted TSDB (survives down -v)    [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: 2 replicas + Thanos Querier (dedupe-at-query)          [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 2-replica + Thanos cluster covers HA.)

> **Auth:** Prometheus has **no built-in auth** — the UI/API bind a network interface and you restrict
> access at the firewall (production: a reverse proxy with auth). These tests run over an AWS SG that only
> admits the test box.
>
> **HA = replicas + dedupe.** Prometheus HA is **two identical replicas** scraping the same targets; a
> **Thanos Querier** fans out to both and **deduplicates** by a `replica` external label, so a replica
> failure is invisible at query time. The `04_docker_cluster` variant is exactly that.

## The shared test script — `test.sh`

Uses **`curl`** against the HTTP API. Prometheus is **pull-based**, so this is a **read-only** smoke (no
throwaway data to clean): it checks `/-/healthy` + `/-/ready`, the build version, queries the `up` metric
(Prometheus scrapes itself, so `up == 1`), and confirms a scrape target is `up`. It works against a single
Prometheus **or** the Thanos Querier (same Prometheus-compatible query API).

### How to run it

```bash
bash test.sh 01_native_single     # native (reads its .env)
bash test.sh 03_docker_single     # docker single-node
bash test.sh "http://host:10902"  # the cluster's Thanos Querier / ANY Prometheus, incl. cross-host
```

### Reading the result

`RESULT: PASS — Prometheus healthy, querying, scraping (read-only).` and exit `0` means it is healthy,
serving queries, and scraping. (`up` may take ~1 scrape interval to appear after a fresh start — the test
polls for it.)

## See also

- `../README.md` — the utility-dependency overview.
- `../../dependencies/07_Observability/02_Prometheus_3.12/` — the original install scripts + the
  `cluster_mode/run_book.md` two-replica + Thanos HA reference.
