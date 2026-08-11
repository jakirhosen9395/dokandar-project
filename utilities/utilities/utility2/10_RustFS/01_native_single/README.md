# RustFS — native single-node (no Docker)

The official RustFS static (musl) binary installed to `/usr/local/bin`, run by **systemd** as the `rustfs`
service, with a single data dir under **`/data/rustfs`**, the built-in **console** on `:9001` and the S3
API on `:9000`. **S3-compatible** object storage — the DOKANDAR object-store exit path (replaces MinIO).
Tested on Ubuntu 26.04 (resolute).

- **What runs:** the upstream `rustfs` static binary (pinned `1.0.0-beta.8`), under systemd as a
  dedicated `rustfs` system user, with the built-in web console enabled.
- **Data:** `${DATA_ROOT}/rustfs` (default `/data/rustfs`). Install is **non-destructive** (an existing
  `/data/rustfs` is reused, never wiped); uninstall **keeps the objects**.
- **Browser UI:** the built-in RustFS console at `http://<host>:9001` (log in with the access/secret keys).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (auto-generates the S3 access key (20 hex) + secret key (40 hex), enables the console, prints a
connection summary); and **B. Manual** — raw copy-paste Ubuntu commands that run the exact same steps by
hand, no script. Both produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit ports / listen address / fixed keys
```

`.env` is gitignored (it holds the real keys); only `.env.example` is committed. Key vars: `DATA_ROOT`,
`RUSTFS_VERSION`, `RUSTFS_ACCESS_KEY`, `RUSTFS_SECRET_KEY`, `RUSTFS_API_PORT` (9000), `RUSTFS_CONSOLE_PORT`
(9001), `RUSTFS_LISTEN` (`0.0.0.0` exposes S3 + console off-box, SG-fenced + key-gated; `127.0.0.1` =
loopback only). **Leave `RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY` empty to auto-generate AWS-shape keys on
install** — they are shown once and saved back to `.env`. With the script you can skip the edit entirely;
with the manual path you choose the keys yourself in the commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                          # auto-generates the access (20 hex) + secret (40 hex) keys
sudo bash setup.sh install --gen-keys               # rotate both keys
sudo bash setup.sh install --access KEY --secret KEY   # set fixed keys explicitly
```

Prints **numbered step output** (1/4 … 4/4 with ✓ ticks) and ends with a **connection summary** — S3
endpoint, access key, secret key, console URL, the cross-host test command, and the data directory. The
keys are **shown once** and persisted to `.env` (chmod 600). Idempotent (4 steps): resolves the keys +
prepares `/data/rustfs`, downloads the static musl binary, writes + starts the systemd unit (server +
console), then verifies the keys with `mc ls`. **A no-flag re-run reuses the stored keys.** Key
resolution: `--access`/`--secret` > a non-empty value in `.env` > auto-generated.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. RustFS has **no
apt repo**: you install the upstream static (musl) binary directly. Choose your own keys where shown.

```bash
# 1. data dir (non-destructive — an existing /data/rustfs is reused)
sudo mkdir -p /data/rustfs

# 2. download + install the RustFS 1.0.0-beta.8 static (musl) binary
sudo apt-get update -y
sudo apt-get install -y wget curl unzip ca-certificates
rm -rf /tmp/rfsdl && mkdir -p /tmp/rfsdl
wget -qO /tmp/rfsdl/r.zip "https://github.com/rustfs/rustfs/releases/download/1.0.0-beta.8/rustfs-linux-x86_64-musl-v1.0.0-beta.8.zip"
unzip -oq /tmp/rfsdl/r.zip -d /tmp/rfsdl
sudo install -m 0755 /tmp/rfsdl/rustfs /usr/local/bin/rustfs
rm -rf /tmp/rfsdl
/usr/local/bin/rustfs --version

# 3. dedicated system user + own the data dir
id rustfs >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin rustfs
sudo chown -R rustfs:rustfs /data/rustfs

# 4. S3 keys → EnvironmentFile (pick your own; 20-hex access / 40-hex secret is the AWS shape)
sudo tee /etc/default/rustfs >/dev/null <<'ENV'
RUSTFS_ACCESS_KEY=ChangeMe_AccessKey
RUSTFS_SECRET_KEY=ChangeMe_StrongSecretKey
ENV
sudo chmod 600 /etc/default/rustfs

# 5. systemd unit — server + built-in console (binds 0.0.0.0; use 127.0.0.1 for loopback only)
sudo tee /etc/systemd/system/rustfs.service >/dev/null <<'UNIT'
[Unit]
Description=RustFS object storage
After=network-online.target
Wants=network-online.target
[Service]
User=rustfs
Group=rustfs
EnvironmentFile=/etc/default/rustfs
ExecStart=/usr/local/bin/rustfs server /data/rustfs --address 0.0.0.0:9000 --console-enable --console-address 0.0.0.0:9001
Restart=on-failure
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now rustfs

# 6. verify — service active + S3 API live (200) + authenticated ListBuckets via mc
systemctl is-active rustfs                                              # -> active
# WAIT for the S3 API to answer before the mc check (the server takes a moment to bind;
# poll /health until 200, like setup.sh does — don't race it with a single immediate curl)
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/health)" = 200 ]; do sleep 2; done
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/health   # -> 200
docker run --rm -i --network host \
  -e MC_HOST_rfs="http://ChangeMe_AccessKey:ChangeMe_StrongSecretKey@127.0.0.1:9000" \
  minio/mc:latest --no-color ls rfs                                    # -> ListBuckets OK (no error)
```

> **The `mc` client:** RustFS is S3-compatible, so the MinIO `mc` client works against it. The verify step
> above runs it in a throwaway `minio/mc` Docker container (`--network host`, ephemeral `MC_HOST_<alias>`
> form — no `~/.mc` residue). If you have `mc` on the host, the equivalent is
> `mc alias set rfs http://127.0.0.1:9000 <access> <secret> && mc ls rfs`.

## Test

The shared contract test lists buckets (auth), creates a **throwaway** bucket, PUTs 2 bilingual-UTF-8
objects, GETs them back byte-identical, asserts the list count, stats, server-side copies, then **removes
everything and proves zero residue**.

### A. Scripted test (the shared contract test)

```bash
# from utility/10_RustFS/  (auto-reads the keys + port from 01_native_single/.env)
bash ../test.sh 01_native_single

# cross-host (test client ≠ this host) — paste the keys setup.sh printed:
RUSTFS_HOST=<host> RUSTFS_API_PORT=9000 RUSTFS_ACCESS_KEY=<ak> RUSTFS_SECRET_KEY=<sk> bash ../test.sh
```

Exits `0` and prints `RESULT: PASS` when every check passes and nothing is left behind.

### B. Manual test (raw write → read → clean-up)

```bash
# point mc at the server (use your actual keys); the rest is one PUT → GET (UTF-8) → drop, zero residue
export MC_HOST_rfs="http://ChangeMe_AccessKey:ChangeMe_StrongSecretKey@127.0.0.1:9000"
MC(){ docker run --rm -i --network host -e MC_HOST_rfs="$MC_HOST_rfs" minio/mc:latest --no-color "$@"; }

MC mb rfs/dokandar-smoke                                          # create a throwaway bucket
printf '%s' 'hello-চাল-dokandar' | MC pipe rfs/dokandar-smoke/probe.txt   # PUT a UTF-8 object
MC cat rfs/dokandar-smoke/probe.txt                              # GET it back -> hello-চাল-dokandar
MC rm --recursive --force rfs/dokandar-smoke                     # remove the object …
MC rb --force rfs/dokandar-smoke                                 # … and the bucket (zero residue)
MC ls rfs                                                        # -> dokandar-smoke is gone
```

## Status / logs

```bash
sudo bash setup.sh status        # service + S3 /health + data-dir size
# manual equivalents:
systemctl is-active rustfs && curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/health
journalctl -u rustfs -n 80 -f
```

## Uninstall

### A. Scripted uninstall

Removes the binary + unit but **keeps the objects** at `/data/rustfs`:

```bash
sudo bash setup.sh uninstall     # stop + remove binary/unit; DATA PRESERVED at /data/rustfs
sudo bash setup.sh purge         # also deletes /data/rustfs + the rustfs user (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + disable, remove the unit + EnvironmentFile + binary (keeps the objects on /data)
sudo systemctl stop rustfs
sudo systemctl disable rustfs
sudo rm -f /etc/systemd/system/rustfs.service /etc/default/rustfs /usr/local/bin/rustfs
sudo systemctl daemon-reload

# full wipe — ALSO delete the objects + the rustfs user (irreversible)
sudo rm -rf /data/rustfs
sudo userdel rustfs
```

## Notes

- S3-compatible — connect with any AWS SDK / `aws s3` CLI / `mc` client at `http://<host>:9000`.
- Single node = no erasure coding / no HA. For HA use `04_docker_cluster` (distributed RustFS).

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../03_docker_single/` — the single-container Docker variant; `../04_docker_cluster/` — the 4-node
  distributed (HA) variant.
- `../../../dependencies/03_Databases_datastores/11_MinIO/` — the frozen MinIO component RustFS replaces;
  its "Install on Ubuntu (no Docker)" / "Testing" sections are the command-shape reference these mirror
  (RustFS is the forward path per `CLAUDE.md` §2).
