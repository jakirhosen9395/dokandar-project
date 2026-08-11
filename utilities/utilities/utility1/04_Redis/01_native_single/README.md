# Redis 8 — native single-node (no Docker)

The cache + coordination layer for DOKANDAR (cart sessions, rate-limit, Redlock, dedup, pub/sub
fan-out). This variant installs `redis-server` **natively** on an Ubuntu host (systemd-managed, **no
Docker**), driven by an env file, with data under `/data/redis` (AOF persistence, preserved on
uninstall). Tested on **Ubuntu 26.04 (resolute)**, which ships `redis-server` 8.x in the base apt repo.

- **What runs:** `redis-server` from the Ubuntu base archive, managed by systemd
  (`redis-server.service`), auth **ON** (`requirepass`, the ACL `default` user).
- **Data:** `${DATA_ROOT}/redis` (default `/data/redis`), symlinked from `/var/lib/redis`, **AOF**
  (`appendonly yes`). Install is **non-destructive** (existing `/data` is reused, never wiped);
  uninstall **keeps the data**.
- **Browser UI:** none (Redis has no web console — use `redis-cli` / the RedisInsight desktop app).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates a complex password, prints a credentials summary); and **B. Manual** — raw
copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit port / bind address / a fixed password
```

`.env` is gitignored (it holds the real password); only `.env.example` is committed. Key vars:
`DATA_ROOT`, `REDIS_PORT`, `REDIS_BIND`, `REDIS_PASSWORD`, `REDIS_MAXMEMORY`. **Leave `REDIS_PASSWORD`
empty to auto-generate a complex (24-char) password on install** — it is shown once and saved back to
`.env`. `REDIS_BIND` defaults to `0.0.0.0` so a remote client can reach it (`requirepass` is required);
set `127.0.0.1` to restrict to loopback. Auth is **always on**. With the script you can skip the edit and
pass the password as a flag; with the manual path you choose the password yourself in the commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                 # auto-generates a complex password
sudo bash setup.sh install --password 'MyOwnSecret'   # or set the password explicitly
sudo bash setup.sh install --gen-password  # force a fresh generated password (rotate)
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks) and ends with a **credentials summary** —
endpoint, the `default` user, password, connection URL, and the `redis-cli` ping command. The password is
**shown once** and persisted to `.env` (chmod 600). Idempotent: prepares `/data/redis` (preserving any
existing AOF), installs `redis-server`, writes a `# >>> dokandar managed >>>` block to
`/etc/redis/redis.conf` (`bind`, `port`, `requirepass`, `appendonly yes`, `maxmemory` + `allkeys-lru`),
then restarts and verifies `PING -> PONG`. **A no-flag re-run reuses the stored password.** Password
resolution: `--password` > a non-empty `REDIS_PASSWORD` in `.env` > auto-generated.

> `--user`/`--db` do **not** apply — Redis has a single `default` ACL user and numbered DBs 0–15.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
password where shown. **Do the `/var/lib/redis` → `/data` symlink *before* the service first writes**, so
the AOF lands on `/data` rather than the root disk.

```bash
# 1. point the data dir at /data BEFORE writing data (non-destructive — copies any existing data over)
sudo systemctl stop redis-server 2>/dev/null || true
sudo mkdir -p /data/redis
[ -d /var/lib/redis ] && sudo cp -a /var/lib/redis/. /data/redis/ 2>/dev/null || true
sudo rm -rf /var/lib/redis && sudo ln -sfn /data/redis /var/lib/redis

# 2. install redis-server from the Ubuntu 26.04 base archive (ships redis-server.service)
sudo apt-get update -y
sudo apt-get install -y redis-server

# 3. write the managed config block (bind 0.0.0.0, port 6379, requirepass, AOF, maxmemory) — pick your own password
sudo chown -R redis:redis /data/redis
sudo sed -i '/^# >>> dokandar managed >>>/,/^# <<< dokandar managed <<</d' /etc/redis/redis.conf 2>/dev/null || true
sudo tee -a /etc/redis/redis.conf >/dev/null <<'CONF'
# >>> dokandar managed >>>
bind 0.0.0.0
port 6379
protected-mode yes
requirepass ChangeMe_StrongPassword
dir /data/redis
appendonly yes
maxmemory 256mb
maxmemory-policy allkeys-lru
# <<< dokandar managed <<<
CONF

# 4. enable + restart the daemon
sudo systemctl enable redis-server
sudo systemctl restart redis-server

# 5. verify (auth required now)
systemctl is-active redis-server                                          # -> active
redis-cli -h 127.0.0.1 -p 6379 -a 'ChangeMe_StrongPassword' ping          # -> PONG
redis-cli -h 127.0.0.1 -p 6379 -a 'ChangeMe_StrongPassword' info server | grep redis_version   # -> redis_version:8.x
```

> **Older Ubuntu (24.04 "noble" / 22.04):** the base archive predates Redis 8 — add the official Redis
> repo **before** step 2 (do **not** add it on 26.04 "resolute", which has no upstream `resolute` release):
>
> ```bash
> sudo apt-get install -y lsb-release curl gpg
> curl -fsSL https://packages.redis.io/gpg | sudo gpg --dearmor -o /usr/share/keyrings/redis-archive-keyring.gpg
> echo "deb [signed-by=/usr/share/keyrings/redis-archive-keyring.gpg] https://packages.redis.io/deb $(lsb_release -cs) main" | sudo tee /etc/apt/sources.list.d/redis.list
> sudo apt-get update
> ```
>
> If you added that repo, remove it by hand on uninstall:
> `sudo rm -f /etc/apt/sources.list.d/redis.list /usr/share/keyrings/redis-archive-keyring.gpg && sudo apt-get update`.

## Test

The shared contract test creates throwaway keys under a hash-tagged prefix `{dokandar_test_<ts>}`,
exercises strings / counter / TTL / list / hash / set / sorted-set + bilingual UTF-8 (`চাল`), then
**deletes them all and proves zero residue** (multi-key `EXISTS` == 0). Never touches other keys.

### A. Scripted test (the shared contract test)

```bash
# from utility/04_Redis/  (auto-reads the host/port + generated password from 01_native_single/.env)
bash test.sh 01_native_single

# or pass the connection explicitly (use your actual password)
bash test.sh "redis://default:<your-password>@127.0.0.1:6379"
```

Exits `0` and prints `RESULT: PASS — test keys deleted, zero residue.` when every check passes.

### B. Manual test (raw write → read → clean-up)

```bash
# write → read round-trip (incl. the UTF-8 চাল round-trip), then DEL the test keys (zero residue)
PW='<your-password>'
redis-cli -h 127.0.0.1 -p 6379 -a "$PW" --no-auth-warning set dokandar:smoke 'hello-চাল-dokandar'
redis-cli -h 127.0.0.1 -p 6379 -a "$PW" --no-auth-warning get dokandar:smoke      # -> hello-চাল-dokandar
redis-cli -h 127.0.0.1 -p 6379 -a "$PW" --no-auth-warning del dokandar:smoke       # -> (integer) 1
redis-cli -h 127.0.0.1 -p 6379 -a "$PW" --no-auth-warning exists dokandar:smoke    # -> (integer) 0  (zero residue)
```

## Status / logs

```bash
sudo bash setup.sh status        # service + PING + data-dir size
# manual equivalents:
systemctl is-active redis-server && redis-cli -h 127.0.0.1 -p 6379 -a '<your-password>' --no-auth-warning ping
journalctl -u redis-server -n 80 -f
```

## Uninstall

### A. Scripted uninstall

Removes the package and config/logs but **keeps the data** at `/data/redis`:

```bash
sudo bash setup.sh uninstall     # package + config/logs removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/redis (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + drop the data symlink (keeps the data on /data)
sudo systemctl stop redis-server
sudo rm -f /var/lib/redis        # this is the symlink, not the data

# purge package + config/logs (data on /data is NOT touched)
sudo apt-get purge -y redis-server redis-tools
sudo apt-get autoremove --purge -y
sudo rm -rf /etc/redis /var/log/redis

# full wipe — ALSO delete the data (irreversible)
sudo rm -rf /data/redis
```

## See also

- `../README.md` — the Redis utility overview + how to use `test.sh` across all variants.
- `../03_docker_single/` — the Docker Compose single-node variant.
- `../04_docker_cluster/` — the Docker Compose Redis Cluster (3 primaries + 3 replicas) variant.
- `../../../dependencies/03_Databases_datastores/04_Redis_8/` — the original install scripts + the
  canonical manual-install reference these commands mirror (incl. the `cluster_mode/run_book.md`).
