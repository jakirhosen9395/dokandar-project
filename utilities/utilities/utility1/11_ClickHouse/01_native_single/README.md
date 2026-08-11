# ClickHouse 26.3 LTS — native single-node (no Docker)

The columnar **OLAP warehouse** for DOKANDAR (owned by `11-reporting`). This variant installs ClickHouse
26.3 LTS from the **official ClickHouse apt repo**, run by **systemd** (`clickhouse-server`), data under
**`/data/clickhouse`** (symlinked, preserved on uninstall). HTTP interface `:8123` (with the built-in
**/play** SQL console), native TCP `:9000`. The `default` SQL user's password is set via a `users.d`
drop-in.

- **What runs:** `clickhouse-server` + `clickhouse-client` + `clickhouse-common-static`, pinned to the
  `26.3.*` train, under the `clickhouse-server.service` systemd unit.
- **Data:** `${DATA_ROOT}/clickhouse` (default `/data/clickhouse`), symlinked from `/var/lib/clickhouse`.
  Install is **non-destructive** (an existing `/var/lib/clickhouse` cluster is copied into `/data`, never
  wiped); uninstall **keeps the data**.
- **Browser UI:** the **built-in** `/play` SQL console at `http://<host>:8123/play` — no extra binary, no
  Docker. Served by the same HTTP interface the moment `clickhouse-server` is running.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates a complex password, prints a credentials summary); and **B. Manual** — raw
copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit ports / listen address / a fixed password
```

`.env` is gitignored (it holds the real password); only `.env.example` is committed. Key vars:
`CLICKHOUSE_USER`, `CLICKHOUSE_PASSWORD`, `CLICKHOUSE_HTTP_PORT` (`8123`), `CLICKHOUSE_TCP_PORT` (`9000`),
`CLICKHOUSE_LISTEN_HOST` (`0.0.0.0` here — exposes the HTTP `/play` console + native port off-box,
SG-fenced; set `127.0.0.1` to keep it loopback-only), `DATA_ROOT`. **Leave `CLICKHOUSE_PASSWORD` empty to
auto-generate a complex (24-char) password on install** — it is shown once and saved back to `.env`. With
the script you can skip the edit entirely and pass everything as flags; with the manual path you choose
the password yourself in the commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                       # auto-generates a complex password
sudo bash setup.sh install --user default        # name the SQL user (default: default)
sudo bash setup.sh install --password 'MyOwnSecret'   # or set the password explicitly
sudo bash setup.sh install --gen-password        # force a fresh generated password (rotate)
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks) and ends with a **credentials summary** — HTTP
+ native endpoints, user, password, the `/play` URL, a `curl` smoke command, and the cross-host test
line. The password is **shown once** and persisted to `.env` (chmod 600). Idempotent: resolves the creds,
symlinks `/var/lib/clickhouse → /data/clickhouse`, adds the apt repo + installs pinned 26.3, writes the
`config.d` (network) + `users.d` (password) drop-ins, then starts and verifies `SELECT version()` over
HTTP. **A no-flag re-run reuses the stored password.** Password resolution: `--password` > a non-empty
`CLICKHOUSE_PASSWORD` in `.env` > auto-generated.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
password where shown. **Do the `/var/lib/clickhouse` → `/data` symlink *before* `apt install`**, so the
package's data dir lands on `/data` from the start.

```bash
# 1. point the data dir at /data BEFORE installing (non-destructive — copy any existing data in first,
#    exactly as the script does: guarded cp -a, only when /var/lib/clickhouse is a real dir, not a symlink)
sudo mkdir -p /data/clickhouse
if [ -d /var/lib/clickhouse ] && [ ! -L /var/lib/clickhouse ]; then sudo cp -a /var/lib/clickhouse/. /data/clickhouse/; fi
sudo rm -rf /var/lib/clickhouse && sudo ln -sfn /data/clickhouse /var/lib/clickhouse

# 2. add the official ClickHouse apt repo (signing key from the Ubuntu keyserver)
sudo apt-get update -y
sudo apt-get install -y curl gnupg dirmngr ca-certificates apt-transport-https
sudo mkdir -p /etc/apt/keyrings
sudo gpg --batch --keyserver keyserver.ubuntu.com \
  --recv-keys 3A9EA1193A97B548BE1457D48919F6BD2B48D754
sudo gpg --batch --yes --export 3A9EA1193A97B548BE1457D48919F6BD2B48D754 \
  | sudo tee /etc/apt/keyrings/clickhouse.gpg >/dev/null
sudo chmod 0644 /etc/apt/keyrings/clickhouse.gpg
echo "deb [signed-by=/etc/apt/keyrings/clickhouse.gpg] https://packages.clickhouse.com/deb stable main" \
  | sudo tee /etc/apt/sources.list.d/clickhouse.list
sudo apt-get update -y

# 3. install the pinned 26.3 train.  CRITICAL: pass CLICKHOUSE_USER=clickhouse to the install so the
#    package postinst creates the OS service user 'clickhouse' (the systemd unit hardcodes
#    User=clickhouse). Without this, the postinst names the OS user after your SQL user (e.g. 'default')
#    and the server won't start.  (The SQL-user password is set in step 4, not here.)
sudo env CLICKHOUSE_USER=clickhouse CLICKHOUSE_GROUP=clickhouse apt-get install -y \
  clickhouse-server=26.3.* clickhouse-client=26.3.* clickhouse-common-static=26.3.*
sudo chown -R clickhouse:clickhouse /data/clickhouse

# 4. config drop-ins: network (listen host + HTTP/native ports) and the SQL-user password
sudo mkdir -p /etc/clickhouse-server/config.d /etc/clickhouse-server/users.d
sudo tee /etc/clickhouse-server/config.d/dokandar-network.xml >/dev/null <<'XML'
<clickhouse>
    <listen_host>0.0.0.0</listen_host>
    <http_port>8123</http_port>
    <tcp_port>9000</tcp_port>
</clickhouse>
XML
sudo tee /etc/clickhouse-server/users.d/dokandar-password.xml >/dev/null <<'XML'
<clickhouse>
    <users>
        <default>
            <password>ChangeMe_StrongPassword</password>
        </default>
    </users>
</clickhouse>
XML

# 5. start + verify (the HTTP interface also serves /play)
sudo systemctl enable --now clickhouse-server
sudo systemctl restart clickhouse-server
systemctl is-active clickhouse-server                              # -> active
curl -fsS http://127.0.0.1:8123/ping                              # -> Ok.
printf 'SELECT version()' | curl -s -u default:ChangeMe_StrongPassword \
  http://127.0.0.1:8123/ --data-binary @-                          # -> 26.3.x
```

> **Pin notes.** `26.3.*` lets apt resolve the latest 26.3 patch (the script resolves it the same way via
> `apt-cache madison`). To freeze the pin against later `apt upgrade`, add
> `sudo apt-mark hold clickhouse-server clickhouse-client clickhouse-common-static`.

## Test

The contract/smoke test confirms connectivity + auth (`SELECT 1`), then creates a **throwaway** database
+ MergeTree table, inserts bilingual UTF-8 rows, reads them back (count / value / aggregate), then
**drops the database and proves zero residue**.

### A. Scripted test (the shared contract test)

```bash
# from utility/11_ClickHouse/  (auto-reads user + the generated password from 01_native_single/.env)
bash test.sh 01_native_single

# or pass the connection explicitly (use your actual password)
CLICKHOUSE_HOST=127.0.0.1 CLICKHOUSE_USER=default CLICKHOUSE_PASSWORD='<your-password>' bash test.sh
```

Exits `0` and prints `RESULT: PASS` when every check passes and nothing is left behind.

### B. Manual test (raw write → read → clean-up)

```bash
# write → read round-trip over the HTTP interface, then drop the db (zero residue)
H='http://127.0.0.1:8123'; A='default:ChangeMe_StrongPassword'
printf '%s' "CREATE DATABASE dokandar_smoke"                                  | curl -s -u "$A" "$H/" --data-binary @-
printf '%s' "CREATE TABLE dokandar_smoke.t (id UInt64, name String) ENGINE=MergeTree ORDER BY id" | curl -s -u "$A" "$H/" --data-binary @-
printf '%s' "INSERT INTO dokandar_smoke.t VALUES (1,'চাল-rice'),(2,'ডিম-egg'),(3,'মাছ-fish')"      | curl -s -u "$A" "$H/" --data-binary @-
printf '%s' "SELECT count() FROM dokandar_smoke.t"                            | curl -s -u "$A" "$H/" --data-binary @-   # -> 3
printf '%s' "SELECT name FROM dokandar_smoke.t WHERE id=1"                    | curl -s -u "$A" "$H/" --data-binary @-   # -> চাল-rice
printf '%s' "DROP DATABASE dokandar_smoke"                                    | curl -s -u "$A" "$H/" --data-binary @-
printf '%s' "SELECT count() FROM system.databases WHERE name='dokandar_smoke'"| curl -s -u "$A" "$H/" --data-binary @-   # -> 0 (zero residue)
```

> Prefer the bundled native client? `clickhouse-client --host 127.0.0.1 --port 9000 --user default
> --password '<pw>' -q 'SELECT version()'` runs the same round-trip over native TCP.

## Status / logs

```bash
sudo bash setup.sh status        # service + HTTP /ping + query + data-dir size
# manual equivalents:
systemctl is-active clickhouse-server && curl -fsS http://127.0.0.1:8123/ping
sudo journalctl -u clickhouse-server -n 80 --no-pager
```

## Uninstall

### A. Scripted uninstall

Removes the packages, config, logs and apt repo but **keeps the data** at `/data/clickhouse`:

```bash
sudo bash setup.sh uninstall     # packages + config/logs + repo removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/clickhouse + the clickhouse OS user (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop FIRST, then purge every clickhouse package by exact name. An apt glob alone can miss
# clickhouse-common-static, which OWNS /usr/bin/clickhouse — never 'rm' that binary by hand.
sudo systemctl stop clickhouse-server
sudo systemctl disable clickhouse-server
sudo apt-get purge -y $(dpkg-query -W -f='${Package} ' 'clickhouse*' 2>/dev/null) \
  clickhouse-server clickhouse-client clickhouse-common-static
sudo apt-get autoremove --purge -y
sudo rm -rf /etc/clickhouse-server /etc/clickhouse-client /var/log/clickhouse-server
sudo rm -f /etc/apt/sources.list.d/clickhouse.list /etc/apt/keyrings/clickhouse.gpg
sudo rm -f /var/lib/clickhouse        # this is the symlink, not the data on /data
sudo apt-get update -y

# full wipe — ALSO delete the data + the clickhouse OS user (irreversible)
sudo rm -rf /data/clickhouse
sudo userdel clickhouse 2>/dev/null; sudo groupdel clickhouse 2>/dev/null
```

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../03_docker_single/` — the Docker single-node variant; `../04_docker_cluster/` — the 3-replica +
  Keeper HA cluster.
- `../../../dependencies/03_Databases_datastores/07_ClickHouse_26.3_LTS/` — the original install scripts +
  the canonical manual-install / testing reference these commands mirror (incl. the single-box memory-cap
  caveat and the native Keeper `cluster_mode/` runbook).
