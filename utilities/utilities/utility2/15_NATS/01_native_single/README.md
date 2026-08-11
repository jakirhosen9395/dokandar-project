# NATS JetStream 2.14 — native single-node (no Docker)

The real-time messaging edge for DOKANDAR. This variant installs the official `nats-server` 2.14 binary
**natively** on an Ubuntu host (systemd-managed, **no Docker**), with **JetStream ON**, a single
auto-generated auth token, the JetStream store under `/data/nats/jetstream` (preserved on uninstall),
client `:4222`, and JSON monitoring `:8222`. Tested on **Ubuntu 26.04 (resolute)**.

- **What runs:** the upstream static `nats-server` v2.14.2 binary at `/usr/local/bin/nats-server`, driven
  by `/etc/nats/nats.conf` (JetStream + token auth), under a `nats` system user.
- **Data:** `${DATA_ROOT}/nats` (default `/data/nats`); the JetStream store is `${DATA_ROOT}/nats/jetstream`.
  Install is **non-destructive** (existing `/data` is reused, never wiped); uninstall **keeps the data**.
- **Browser UI:** none — NATS has no HTML console. `:8222` serves **JSON** monitoring only (`/healthz`,
  `/varz`, `/jsz`). Observe it with the `nats` CLI, `nats-top`, or by scraping those endpoints.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates the token, writes the config + systemd unit, prints a connection summary); and
**B. Manual** — raw copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both
produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit the token / ports / bind address
```

`.env` is gitignored (it holds the real token); only `.env.example` is committed. Key vars:
`NATS_AUTH_TOKEN`, `NATS_CLIENT_PORT` (default `4222`), `NATS_MONITOR_PORT` (default `8222`), `NATS_HOST`
(default `0.0.0.0`), `DATA_ROOT` (default `/data`). **Leave `NATS_AUTH_TOKEN` empty to auto-generate a
complex (24-char) token on install** — it is shown once and saved back to `.env`. With the script you can
skip the edit entirely; with the manual path you choose the token yourself in the commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                  # auto-generates the token
sudo bash setup.sh install --token 'mytok'  # or set the token explicitly
sudo bash setup.sh install --gen-token      # force a fresh generated token (rotate)
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks) and ends with a **connection summary** — client
URL (`nats://<token>@host:4222`), auth token, the monitoring URL, the `nats` CLI smoke command, and the
JetStream store path. The token is **shown once** and persisted to `.env` (chmod 600). Idempotent:
resolves the token + store dir, downloads the pinned `nats-server` binary, writes `nats.conf`
(JetStream + token) + the systemd unit and starts it, waits for `/healthz`, then verifies JetStream
(`/healthz?js-enabled-only=true`). **A no-flag re-run reuses the stored token.** Token resolution:
`--token` > a non-empty `NATS_AUTH_TOKEN` in `.env` > auto-generated.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
token where shown. There is **no apt repo and no symlink** for this variant: the binary is downloaded
from the upstream GitHub release and the JetStream store is written straight to `/data/nats/jetstream`.

```bash
# 1. create the JetStream store dir under /data (non-destructive)
sudo mkdir -p /data/nats/jetstream

# 2. download + install the pinned nats-server binary (no apt repo — upstream static Go binary)
VER=2.14.2
sudo apt-get install -y wget curl ca-certificates
wget -qO /tmp/nats.tgz "https://github.com/nats-io/nats-server/releases/download/v${VER}/nats-server-v${VER}-linux-amd64.tar.gz"
tar -xzf /tmp/nats.tgz -C /tmp
sudo install -m 0755 "/tmp/nats-server-v${VER}-linux-amd64/nats-server" /usr/local/bin/nats-server
sudo rm -rf /tmp/nats.tgz "/tmp/nats-server-v${VER}-linux-amd64"
/usr/local/bin/nats-server --version        # -> nats-server: v2.14.x

# 3. create the nats system user + own the data dir
sudo useradd --system --no-create-home --shell /usr/sbin/nologin nats || true
sudo chown -R nats:nats /data/nats

# 4. write the config (JetStream ON + token auth) — pick your own token
sudo mkdir -p /etc/nats
sudo tee /etc/nats/nats.conf >/dev/null <<'CONF'
listen: 0.0.0.0:4222
http: 0.0.0.0:8222
server_name: dokandar-nats-1
jetstream {
  store_dir: "/data/nats/jetstream"
}
authorization {
  token: "ChangeMe_StrongToken"
}
CONF
sudo chmod 640 /etc/nats/nats.conf && sudo chown root:nats /etc/nats/nats.conf

# 5. systemd unit, enable + start
sudo tee /etc/systemd/system/nats.service >/dev/null <<'UNIT'
[Unit]
Description=NATS JetStream server
After=network-online.target
Wants=network-online.target
[Service]
User=nats
ExecStart=/usr/local/bin/nats-server -c /etc/nats/nats.conf
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now nats

# 6. verify the server + JetStream
systemctl is-active nats                                                       # -> active
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8222/healthz       # -> 200
curl -fsS -o /dev/null -w '%{http_code}\n' "http://127.0.0.1:8222/healthz?js-enabled-only=true"  # -> 200 (JetStream on)
```

## Test

The shared contract test confirms connectivity + JetStream, then creates a **throwaway KV bucket**, puts a
bilingual UTF-8 value (`চাল-rice`), reads it back byte-identical, then **deletes the key + bucket and proves
zero residue**. It uses the `nats` CLI on the host, or `natsio/nats-box` in a `--network host` container if
no host `nats` is present.

### A. Scripted test (the shared contract test)

```bash
# from utility/15_NATS/  (auto-reads host/port/token from 01_native_single/.env)
bash test.sh 01_native_single

# or pass the connection explicitly (cross-host; use your actual token)
NATS_HOST=<host> NATS_AUTH_TOKEN='<your-token>' bash test.sh
```

Exits `0` and prints `RESULT: PASS` when every check passes and nothing is left behind.

### B. Manual test (raw write → read → clean-up)

```bash
# the `nats` CLI is a SEPARATE binary (the native install ships only nats-server) — install it first,
# pinned, from the upstream zip (same as the run book), to /usr/local/bin/nats
CV=0.4.0
sudo apt-get install -y unzip curl ca-certificates
curl -fsSL -o /tmp/natscli.zip "https://github.com/nats-io/natscli/releases/download/v${CV}/nats-${CV}-linux-amd64.zip"
rm -rf /tmp/natsclix; unzip -q -o /tmp/natscli.zip -d /tmp/natsclix
sudo install -m 0755 "/tmp/natsclix/nats-${CV}-linux-amd64/nats" /usr/local/bin/nats
rm -rf /tmp/natscli.zip /tmp/natsclix

# point the nats CLI at the server (token auth)
URL="nats://ChangeMe_StrongToken@127.0.0.1:4222"

# connectivity + JetStream is responding
nats -s "$URL" account info | grep -iE 'JetStream|Streams'

# create a throwaway KV bucket, put a UTF-8 value, read it back byte-identical
nats -s "$URL" kv add DOKTEST --replicas=1 --history=1
nats -s "$URL" kv put DOKTEST rice 'চাল-rice'
nats -s "$URL" kv get DOKTEST rice --raw          # -> চাল-rice

# delete the key + bucket and prove zero residue
nats -s "$URL" kv del DOKTEST rice -f
nats -s "$URL" kv rm  DOKTEST -f
nats -s "$URL" kv ls | grep -q DOKTEST && echo 'RESIDUE!' || echo 'clean — zero residue'
```

> No host `nats` CLI? Run the same commands through `natsio/nats-box`, e.g.
> `docker run --rm --network host natsio/nats-box:latest nats -s "$URL" account info`.

## Status

```bash
sudo bash setup.sh status        # service + /healthz + JetStream-on check + store size
# manual equivalent:
systemctl is-active nats && curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8222/healthz
```

## Uninstall

### A. Scripted uninstall

Removes the binary, config, and systemd unit but **keeps the data** at `/data/nats`:

```bash
sudo bash setup.sh uninstall     # binary + unit + config removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/nats and the nats user (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + disable the service, remove the unit, binary, and config (data on /data is NOT touched)
sudo systemctl stop nats
sudo systemctl disable nats
sudo rm -f /etc/systemd/system/nats.service /usr/local/bin/nats-server
sudo rm -rf /etc/nats
sudo systemctl daemon-reload

# full wipe — ALSO delete the JetStream store + the nats user (irreversible)
sudo rm -rf /data/nats
sudo userdel nats
```

## Notes

- **No browser UI** — `:8222` serves JSON (`/healthz`, `/varz`, `/jsz`). Use the `nats` CLI or `nats-top`.
- Single node = no R3 replication / no HA (JetStream streams are R1). For HA use `04_docker_cluster`
  (3-node mesh) or the native `cluster_mode` run book.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../03_docker_single/` — the Docker single-node variant.
- `../04_docker_cluster/` — the Docker HA cluster (3-node mesh).
- `../../../dependencies/04_Messaging_streaming/03_NATS_JetStream_2.14/` — the original install scripts +
  the canonical manual-install reference these commands mirror.
