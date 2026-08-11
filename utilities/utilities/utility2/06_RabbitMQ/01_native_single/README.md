# RabbitMQ 4.x — native single-node (no Docker)

The **command / task-queue** broker for DOKANDAR (durable quorum queues for `payout.execute` and
`notifications.*`). This variant installs a single `rabbitmq-server` **natively** on an Ubuntu host
(systemd-managed, **no Docker**, pulls Erlang/OTP), driven by an env file, with data under
`/data/rabbitmq` (preserved on uninstall). Auth is ON (an admin user; the stock `guest` is deleted), and
the **Management plugin** (web UI + HTTP API) is enabled on `:15672`.

- **What runs:** the `rabbitmq-server` package (from the Ubuntu archive — pulls a matching Erlang/OTP),
  with the `rabbitmq_management` plugin enabled.
- **Data:** `${DATA_ROOT}/rabbitmq` (default `/data/rabbitmq`), symlinked from `/var/lib/rabbitmq`.
  Install is **non-destructive** (existing `/data` is reused, never wiped); uninstall **keeps the data**.
- **Browser UI:** **yes** — the Management plugin at `http://<host>:15672` (log in with the admin user).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates a complex password, prints a credentials summary); and **B. Manual** — raw
copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both produce the same broker.

## Configure

```bash
cp .env.example .env        # optional — edit user / ports / bind address / a fixed password
```

`.env` is gitignored (it holds the real password); only `.env.example` is committed. Key vars:
`RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, `RABBITMQ_AMQP_PORT` (default `5672`),
`RABBITMQ_MGMT_PORT` (default `15672`), `RABBITMQ_NODE_IP` (default `0.0.0.0` — the interface the AMQP
listener binds; auth always required), `DATA_ROOT`. **Leave `RABBITMQ_DEFAULT_PASS` empty to auto-generate
a complex (24-char) password on install** — it is shown once and saved back to `.env`. With the script you
can skip the edit entirely and pass everything as flags; with the manual path you choose the password
yourself in the commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                              # auto-generates a complex password
sudo bash setup.sh install --user appuser               # name the admin role
sudo bash setup.sh install --password 'MyOwnSecret'     # or set the password explicitly
sudo bash setup.sh install --gen-password               # force a fresh generated password (rotate)
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks) and ends with a **credentials summary** — AMQP
endpoint, user, password, AMQP URL, the browser-UI URL, the HTTP-API URL, and the data directory. The
password is **shown once** and persisted to `.env` (chmod 600). Idempotent: prepares `/data/rabbitmq`
(preserving any existing data), symlinks `/var/lib/rabbitmq` → `/data/rabbitmq`, installs `rabbitmq-server`,
writes `/etc/rabbitmq/conf.d/10-dokandar.conf`, enables the management plugin, creates the admin user
(dropping `guest`), and verifies the user authenticates. **A no-flag re-run reuses the stored password.**
Password resolution: `--password` > a non-empty `RABBITMQ_DEFAULT_PASS` in `.env` > auto-generated.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
user/password where shown. **Do the `/var/lib/rabbitmq` → `/data` symlink and the `chown` *before* the
broker boots**, or the broker hits an `eacces` on its Erlang cookie under the `/data` symlink and refuses
to start.

```bash
# 1. point the data dir at /data BEFORE installing — non-destructive (copy any existing data over)
sudo mkdir -p /data/rabbitmq
sudo systemctl stop rabbitmq-server 2>/dev/null || true
[ -d /var/lib/rabbitmq ] && sudo cp -a /var/lib/rabbitmq/. /data/rabbitmq/ 2>/dev/null || true
sudo rm -rf /var/lib/rabbitmq && sudo ln -sfn /data/rabbitmq /var/lib/rabbitmq

# 2. install rabbitmq-server from the Ubuntu archive (pulls a compatible Erlang/OTP automatically)
sudo apt-get update -y
sudo apt-get install -y rabbitmq-server

# 3. listener + management config (AMQP bind/port + the management UI port)
sudo mkdir -p /etc/rabbitmq/conf.d
sudo tee /etc/rabbitmq/conf.d/10-dokandar.conf >/dev/null <<'CONF'
listeners.tcp.1 = 0.0.0.0:5672
management.tcp.port = 15672
management.tcp.ip = 0.0.0.0
CONF

# 4. the data dir + Erlang cookie MUST be owned by the rabbitmq user (else eacces on the cookie),
#    then clear any failed-start rate limit and (re)start the broker
sudo chown -R rabbitmq:rabbitmq /data/rabbitmq
sudo systemctl reset-failed rabbitmq-server 2>/dev/null || true
sudo systemctl enable --now rabbitmq-server
sudo systemctl restart rabbitmq-server

# wait for the broker to finish booting
for _ in $(seq 1 30); do sudo rabbitmq-diagnostics -q ping >/dev/null 2>&1 && break; sleep 2; done

# 5. enable the Management plugin (web UI + HTTP API on :15672)
sudo rabbitmq-plugins enable rabbitmq_management

# 6. create the admin user, give it the administrator tag + full perms, and drop the stock guest
sudo rabbitmqctl add_user dokandar 'ChangeMe_StrongPassword'
sudo rabbitmqctl set_user_tags dokandar administrator
sudo rabbitmqctl set_permissions -p / dokandar ".*" ".*" ".*"
sudo rabbitmqctl delete_user guest

# 7. verify
systemctl is-active rabbitmq-server                              # -> active
sudo rabbitmq-diagnostics -q ping                                # -> Ping succeeded
sudo rabbitmqctl authenticate_user dokandar 'ChangeMe_StrongPassword'   # -> Success
curl -s -u dokandar:ChangeMe_StrongPassword http://localhost:15672/api/overview | head -c 200; echo
```

> The utility installs `rabbitmq-server` straight from the **Ubuntu archive** (which tracks RabbitMQ
> 4.0.x). For the exact **4.3** pin, follow the Team RabbitMQ apt-repo guide
> (<https://www.rabbitmq.com/docs/install-debian>) **before** step 2 — it adds the signing keys + the
> modern Erlang and RabbitMQ Cloudsmith sources, after which `apt-get install -y rabbitmq-server` lands
> 4.3.x. The docker variants already run `rabbitmq:4-management` (= 4.3.x).

## Test

The contract/smoke test drives the Management HTTP API with `curl`: it creates a throwaway
`dokandar_rabbittest_<ts>` **quorum** queue, publishes a bilingual-UTF-8 message, gets it back, checks the
payload, then **deletes the queue and proves zero residue**.

### A. Scripted test (the shared contract test)

```bash
# from utility/06_RabbitMQ/  (auto-reads user + the generated password from 01_native_single/.env)
bash test.sh 01_native_single

# or point it at any node by management URL (use your actual password)
bash test.sh "http://dokandar:<your-password>@127.0.0.1:15672"
```

Exits `0` and prints `RESULT: PASS — test queue deleted, zero residue.` when every check passes.

### B. Manual test (raw write → read → clean-up)

```bash
U=dokandar; P='ChangeMe_StrongPassword'; B=http://localhost:15672; Q=dokandar_smoke

# create a durable quorum queue
curl -s -u "$U:$P" -H 'content-type: application/json' \
  -X PUT "$B/api/queues/%2F/$Q" -d '{"durable":true,"arguments":{"x-queue-type":"quorum"}}'

# publish a bilingual UTF-8 message via the default exchange (routed by queue name)
curl -s -u "$U:$P" -H 'content-type: application/json' \
  -X POST "$B/api/exchanges/%2F/amq.default/publish" \
  -d "{\"properties\":{},\"routing_key\":\"$Q\",\"payload\":\"chal-চাল-rice\",\"payload_encoding\":\"string\"}"

# get it back + confirm the UTF-8 'চাল' round-trip
curl -s -u "$U:$P" -H 'content-type: application/json' \
  -X POST "$B/api/queues/%2F/$Q/get" \
  -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' | grep -o 'চাল'   # -> চাল

# delete the queue + prove zero residue (lists no dokandar_smoke)
curl -s -u "$U:$P" -X DELETE "$B/api/queues/%2F/$Q"
curl -s -u "$U:$P" "$B/api/queues/%2F?columns=name" | grep -o 'dokandar_smoke' || echo 'clean: 0 test queues'
```

## Status

```bash
sudo bash setup.sh status        # service + ping + user + UI URL + data-dir size
# manual equivalent:
systemctl is-active rabbitmq-server && sudo rabbitmq-diagnostics -q ping
```

## Uninstall

### A. Scripted uninstall

Removes the package and config/logs but **keeps the data** at `/data/rabbitmq`:

```bash
sudo bash setup.sh uninstall     # package + config/logs removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/rabbitmq (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + drop the data symlink (keeps the data on /data)
sudo systemctl stop rabbitmq-server
sudo rm -f /var/lib/rabbitmq        # this is the symlink, not the data

# purge the package + config/logs (data on /data is NOT touched)
sudo apt-get purge -y rabbitmq-server
sudo apt-get autoremove --purge -y
sudo rm -rf /etc/rabbitmq /var/log/rabbitmq

# full wipe — ALSO delete the data (irreversible)
sudo rm -rf /data/rabbitmq
```

## See also

- `../README.md` — the utility overview and how to use `test.sh` across all install variants.
- `../03_docker_single/` — the Docker Compose single-node variant.
- `../../../dependencies/04_Messaging_streaming/02_RabbitMQ_4.3/` — the original install scripts + the
  canonical manual-install / testing reference these commands mirror.
