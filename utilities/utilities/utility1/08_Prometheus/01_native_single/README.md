# Prometheus 3.12 — native single-node (no Docker)

The metrics pull-stack for DOKANDAR. This variant installs Prometheus 3.12 **natively** from the official
upstream binary on an Ubuntu host (systemd-managed, **no Docker**), driven by an env file, with data under
`/data/prometheus` (preserved on uninstall). Built-in expression-browser web UI + HTTP API on `:9090`.
Tested on **Ubuntu 26.04 (resolute)**.

- **What runs:** the upstream `prometheus` + `promtool` static binaries (pinned `3.12.0`) under a systemd
  unit, as an unprivileged `prometheus` system user, scraping itself on `localhost:9090`.
- **Data:** `${DATA_ROOT}/prometheus` (default `/data/prometheus`), symlinked from `/var/lib/prometheus`.
  Install is **non-destructive** (existing `/data` is reused, never wiped); uninstall **keeps the data**.
- **Browser UI:** the built-in Prometheus expression browser at `http://<host>:9090` (no separate binary,
  unit, or port).
- **Auth:** none — Prometheus has **no built-in auth**. The UI/API bind a network interface; restrict
  access at the firewall (production: a reverse proxy with auth).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (downloads the pinned binary, writes the systemd unit, prints a connection summary); and
**B. Manual** — raw copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both
produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit listen address / port / retention
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `PROM_VERSION` (`3.12.0`),
`PROMETHEUS_LISTEN` (default `0.0.0.0`; set `127.0.0.1` for loopback-only), `PROMETHEUS_PORT` (`9090`),
`PROMETHEUS_RETENTION` (`15d`), `DATA_ROOT` (`/data` → TSDB under `${DATA_ROOT}/prometheus`).

## Install

### A. Scripted install (recommended)

```bash
cp .env.example .env        # optional — defaults are sensible
sudo bash setup.sh install
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks) and ends with a **connection summary** — the
HTTP API + UI URL, the `/-/healthy` / `/-/ready` probe URLs, a sample `up` query, the data directory, and
the retention. Idempotent: prepares `/data/prometheus` (preserving any existing TSDB via the
`/var/lib/prometheus` symlink), downloads the pinned `prometheus`/`promtool` binaries (skipped if
already present), creates the `prometheus` user + `/etc/prometheus/prometheus.yml` (scrapes itself),
installs + enables the systemd unit, then polls `/-/healthy` until it answers.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Prometheus does
**not** ship a maintained apt repo, so this installs the upstream static binary directly. **Point
`/var/lib/prometheus` at `/data` *before* the service starts**, so the TSDB lands on `/data`.

```bash
# 1. point the data dir at /data BEFORE starting (non-destructive — copies any existing TSDB first)
sudo mkdir -p /data/prometheus
# preserve a pre-existing real /var/lib/prometheus dir before replacing it with the symlink (no-op on a clean host)
[ -d /var/lib/prometheus ] && [ ! -L /var/lib/prometheus ] && sudo cp -a /var/lib/prometheus/. /data/prometheus/ 2>/dev/null || true
sudo rm -rf /var/lib/prometheus && sudo ln -sfn /data/prometheus /var/lib/prometheus

# 2. download + install the pinned upstream binaries (no apt repo for Prometheus)
VER=3.12.0
sudo apt-get update -y && sudo apt-get install -y wget curl ca-certificates
wget -qO /tmp/prom.tgz "https://github.com/prometheus/prometheus/releases/download/v${VER}/prometheus-${VER}.linux-amd64.tar.gz"
sudo rm -rf /tmp/promx && mkdir -p /tmp/promx
tar -xzf /tmp/prom.tgz -C /tmp/promx --strip-components=1 && rm -f /tmp/prom.tgz
sudo install -m0755 /tmp/promx/prometheus /usr/local/bin/prometheus
sudo install -m0755 /tmp/promx/promtool   /usr/local/bin/promtool
prometheus --version

# 3. create the prometheus user + config (self-scrape) + ownership
sudo groupadd --system prometheus 2>/dev/null || true
id prometheus >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin -g prometheus prometheus
sudo mkdir -p /etc/prometheus
sudo tee /etc/prometheus/prometheus.yml >/dev/null <<'CONF'
global:
  scrape_interval: 15s
  evaluation_interval: 15s
scrape_configs:
  - job_name: prometheus
    static_configs:
      - targets: ["localhost:9090"]
CONF
sudo chown -R prometheus:prometheus /etc/prometheus /data/prometheus

# 4. systemd unit (listen 0.0.0.0:9090, retention 15d, lifecycle API enabled for reloads)
sudo tee /etc/systemd/system/prometheus.service >/dev/null <<'UNIT'
[Unit]
Description=Prometheus
After=network-online.target
Wants=network-online.target
[Service]
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus --config.file=/etc/prometheus/prometheus.yml --storage.tsdb.path=/data/prometheus --storage.tsdb.retention.time=15d --web.listen-address=0.0.0.0:9090 --web.enable-lifecycle
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now prometheus

# 5. verify
systemctl is-active prometheus                                              # -> active
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9090/-/healthy   # -> 200
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9090/-/ready     # -> 200
```

> **Loopback-only:** to bind to localhost instead of all interfaces, use
> `--web.listen-address=127.0.0.1:9090` in the unit (mirrors `PROMETHEUS_LISTEN=127.0.0.1`). On a public
> host expose the UI only through the edge (nginx/Caddy with TLS + auth) — Prometheus has no authn.

## Test

Prometheus is **pull-based**, so the contract test is a **read-only** smoke (nothing to clean up): it
checks `/-/healthy` + `/-/ready`, the build version, queries the `up` metric (Prometheus scrapes itself,
so `up == 1`), and confirms a scrape target is `up`.

### A. Scripted test (the shared contract test)

```bash
# from utility/08_Prometheus/  (defaults to 127.0.0.1:9090 from the variant .env)
bash ../test.sh 01_native_single
bash ../test.sh "http://<host>:9090"    # cross-host (point at this box's IP)
```

Exits `0` and prints `RESULT: PASS — Prometheus healthy, querying, scraping (read-only).`

### B. Manual test (raw write → read → clean-up)

Prometheus is read-only at the API (you cannot insert a sample by query), so the round-trip is exercised
through the **self-scrape**: Prometheus *writes* its own `up` sample into the TSDB and we *read* it back,
then there is nothing to delete (the test leaves zero residue by construction). The UTF-8 round-trip is
proven by querying a metric whose value flows through PromQL unchanged.

```bash
# liveness + readiness
curl -fsS -o /dev/null -w 'healthy=%{http_code}\n' http://127.0.0.1:9090/-/healthy   # -> healthy=200
curl -fsS -o /dev/null -w 'ready=%{http_code}\n'   http://127.0.0.1:9090/-/ready     # -> ready=200

# write→read round-trip: Prometheus scraped itself, so the 'up' series exists and reads back as 1
curl -fsS 'http://127.0.0.1:9090/api/v1/query?query=up' | head -c 300; echo
# -> {"status":"success",...,"value":[<ts>,"1"]...}

# UTF-8 'চাল' round-trips through PromQL unchanged (label values are UTF-8 clean — read, nothing stored)
curl -fsSG 'http://127.0.0.1:9090/api/v1/query' --data-urlencode 'query=label_replace(up,"note","চাল","","")' \
  | grep -o '"note":"চাল"' | head -1                                                  # -> "note":"চাল"

# every scrape target is healthy, and the config is valid (no residue left behind)
curl -fsS http://127.0.0.1:9090/api/v1/targets | grep -oE '"health":"[a-z]+"' | sort | uniq -c   # -> only "up"
promtool check config /etc/prometheus/prometheus.yml                                  # -> SUCCESS
```

## Status / logs

```bash
sudo bash setup.sh status        # service + /-/healthy + data-dir size
# manual equivalents:
systemctl is-active prometheus && curl -fsS http://127.0.0.1:9090/-/healthy
journalctl -u prometheus -n 80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
sudo bash setup.sh uninstall     # stop + remove unit/binaries/config; DATA PRESERVED at /data/prometheus
sudo bash setup.sh purge         # uninstall + delete /data/prometheus (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + disable, then remove the unit, binaries, config, and the data symlink (keeps the data on /data)
sudo systemctl stop prometheus
sudo systemctl disable prometheus
sudo rm -f /etc/systemd/system/prometheus.service
sudo systemctl daemon-reload
sudo rm -f /var/lib/prometheus                       # this is the symlink, not the data
sudo rm -f /usr/local/bin/prometheus /usr/local/bin/promtool
sudo rm -rf /etc/prometheus
# (optional) remove the system user too:
sudo userdel prometheus 2>/dev/null || true

# full wipe — ALSO delete the data (irreversible)
sudo rm -rf /data/prometheus
```

## See also

- `../README.md` — the Prometheus utility overview + the shared `test.sh`.
- `../03_docker_single/` — the single-container Docker variant.
- `../04_docker_cluster/` — the HA variant (2 replicas + Thanos Querier).
- `../../../dependencies/07_Observability/02_Prometheus_3.12/` — the original install scripts + the
  canonical manual-install / testing reference these commands mirror.
