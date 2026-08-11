# MongoDB 7.0 — native single-node (no Docker)

A single `mongod` installed from the official MongoDB apt repo, managed by **systemd**, configured by an
**env file**, with data under **`/data/mongodb`** (symlinked from `/var/lib/mongodb`). Auth is enabled
(built-in `root` user @ `admin`).

> Pinned to **7.0** because `mongod` 8.x SEGFAULT-crashloops on Ubuntu / kernel 7.0 (SERVER-121912).
> MongoDB publishes 7.0 for the **`jammy`** codename (there is **no** `noble`/`resolute` 7.0 repo — they
> 404) — both are set in `.env` (`MONGO_VERSION`, `MONGO_REPO_CODENAME`). See `../README.md` for the full
> rationale.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates a complex password, creates the root user, enables authorization, prints a
credentials summary); and **B. Manual** — raw copy-paste Ubuntu commands that run the exact same steps by
hand, no script. Both produce the same server.

## Files

- `setup.sh` — install / uninstall / purge / status (idempotent; auto-password, `--user`/`--db`/`--password`/`--gen-password`).
- `.env.example` — copy to `.env`; leave `MONGO_ROOT_PASSWORD` empty to auto-generate one.

## Configure

```bash
cp .env.example .env        # optional — edit port / bind IP / a fixed password
```

`.env` is gitignored (it holds the real password); only `.env.example` is committed. Key vars:
`MONGO_VERSION` (`7.0`), `MONGO_REPO_CODENAME` (`jammy`), `MONGO_ROOT_USER` (default `dokandar`),
`MONGO_ROOT_PASSWORD`, `MONGO_INITDB_DATABASE`, `MONGO_PORT` (`27017`), `MONGO_BIND_IP`, `DATA_ROOT`.
**Leave `MONGO_ROOT_PASSWORD` empty to auto-generate a complex (24-char) password on install** — it is
shown once and saved back to `.env`. `MONGO_BIND_IP` defaults to **`0.0.0.0`** so a remote client can reach
it (auth is required); set it to `127.0.0.1` to restrict to loopback. With the script you can skip the
edit entirely and pass everything as flags; with the manual path you choose the password yourself in the
commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                                  # auto-generates a complex password
sudo bash setup.sh install --user dokandar --db dokandar_cart   # name the root user + create a database
sudo bash setup.sh install --password 'MyOwnSecret'         # or set the password explicitly
sudo bash setup.sh install --gen-password                   # force a fresh generated password (rotate)
```

Prints **numbered step output** (1/6 … 6/6 with ✓ ticks) and ends with a **credentials summary** — host,
port, user, password, auth database, connection URI, and the `mongosh` command. The password is **shown
once** and persisted to `.env` (chmod 600). Idempotent, in 6 steps: configuration → data dir
(`/var/lib/mongodb → /data/mongodb`, non-destructive) → apt install (`mongodb-org` + `mongosh`) →
net config + first start with **auth OFF bound to loopback only** → create the `root` user under the
localhost exception (+ optional `--db`) → **enable authorization**, widen `bindIp`, and verify a password
login. **A no-flag re-run reuses the stored password**; `--gen-password` rotates it. Password resolution:
`--password` > a non-empty `MONGO_ROOT_PASSWORD` in `.env` > auto-generated.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
password where shown. **Do the `/var/lib/mongodb` → `/data` symlink *before* `apt install`**, or `mongod`
initialises on the root disk instead of `/data`. The bootstrap binds to **`127.0.0.1` with auth OFF** so
the root user is created over the localhost exception; auth is enabled and `bindIp` widened only at the
end.

```bash
# 1. point the data dir at /data BEFORE installing (so the dbpath lands on /data) — non-destructive
sudo mkdir -p /data/mongodb
sudo rm -rf /var/lib/mongodb && sudo ln -sfn /data/mongodb /var/lib/mongodb

# 2. add MongoDB's 7.0 apt repo (codename MUST be jammy — 7.0 is NOT published for noble/resolute)
sudo apt-get update -y
sudo apt-get install -y wget gnupg curl ca-certificates
sudo install -d -m 0755 /etc/apt/keyrings
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc \
  | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/mongodb-7.0.gpg
echo "deb [signed-by=/etc/apt/keyrings/mongodb-7.0.gpg] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" \
  | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list

# 3. install MongoDB 7.0 (mongodb-org pulls mongod + mongosh + tools)
sudo apt-get update -y
sudo apt-get install -y mongodb-org

# 4. bootstrap: port + bind to LOOPBACK only + auth OFF, then start
sudo chown -R mongodb:mongodb /data/mongodb /var/log/mongodb
sudo sed -i 's/^\(\s*\)port:.*/\1port: 27017/'        /etc/mongod.conf
sudo sed -i 's/^\(\s*\)bindIp:.*/\1bindIp: 127.0.0.1/' /etc/mongod.conf
sudo systemctl enable --now mongod
until mongosh --quiet --host 127.0.0.1 --port 27017 --eval 'db.runCommand({ping:1}).ok' | grep -q 1; do sleep 1; done

# 5. create the root user under the localhost exception (auth still off) — pick your own password
mongosh --quiet --host 127.0.0.1 --port 27017 --eval \
  "db.getSiblingDB('admin').createUser({user:'dokandar',pwd:'ChangeMe_StrongPassword',roles:[{role:'root',db:'admin'}]})"

# 5b. (optional) seed an application database
mongosh --quiet --host 127.0.0.1 --port 27017 --eval \
  "db.getSiblingDB('dokandar_cart').createCollection('_init')"

# 6. enable authorization + widen bindIp to 0.0.0.0 (loopback-only? use 127.0.0.1), then restart
grep -qE '^\s*authorization:' /etc/mongod.conf \
  && sudo sed -i 's/^\(\s*\)authorization:.*/\1authorization: enabled/' /etc/mongod.conf \
  || printf '\nsecurity:\n  authorization: enabled\n' | sudo tee -a /etc/mongod.conf
sudo sed -i 's/^\(\s*\)bindIp:.*/\1bindIp: 0.0.0.0/' /etc/mongod.conf
sudo systemctl restart mongod

# 7. verify a password login (auth ON)
systemctl is-active mongod                                   # -> active
mongosh --quiet --host 127.0.0.1 --port 27017 \
  -u dokandar -p 'ChangeMe_StrongPassword' --authenticationDatabase admin \
  --eval 'db.runCommand({ping:1}).ok'                        # -> 1
```

## Test

The contract/smoke test creates a throwaway `dokandar_mongotest_*` database, exercises
CRUD / aggregation / a UNIQUE index / bilingual UTF-8, then **drops the database and proves zero residue**.
A standalone has no replica set, so the multi-document **transaction check is reported N/A** (expected).

### A. Scripted test (the shared contract test)

```bash
# from utility/02_MongoDB/  (auto-reads user + the generated password from 01_native_single/.env)
bash test.sh 01_native_single

# or from another machine, over the network (use your actual password):
bash test.sh "mongodb://dokandar:<pw>@<host>:27017/?authSource=admin&directConnection=true"
```

Exits `0` and prints `RESULT: PASS` when every check passes and nothing is left behind. Runs in **host
mode** if `mongosh` is on PATH, else **docker mode** (runs `mongosh` in a `mongo:7.0` container).

### B. Manual test (raw write → read → clean-up)

```bash
# write → read round-trip with a UTF-8 'চাল' value, then drop the test db (zero residue)
mongosh --quiet --host 127.0.0.1 --port 27017 \
  -u dokandar -p 'ChangeMe_StrongPassword' --authenticationDatabase admin <<'JS'
db = db.getSiblingDB('dokandar_smoke');
db.probe.insertOne({ name_bn: 'চাল', name_en: 'rice', at: new Date() });
printjson(db.probe.findOne({ name_en: 'rice' }));            // -> { name_bn: 'চাল', ... }
db.dropDatabase();                                           // clean up — zero residue
JS
```

## Status

```bash
sudo bash setup.sh status        # service + ping + version + user + data-dir size
# manual equivalent:
systemctl is-active mongod
mongosh --quiet --host 127.0.0.1 --port 27017 \
  -u dokandar -p 'ChangeMe_StrongPassword' --authenticationDatabase admin \
  --eval 'db.runCommand({ping:1}).ok'        # -> 1
```

## Uninstall

### A. Scripted uninstall

Removes the packages, repo files, config and logs but **keeps the data** at `/data/mongodb`:

```bash
sudo bash setup.sh uninstall     # packages + repo/config/logs removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/mongodb (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + drop the data symlink (keeps the data on /data)
sudo systemctl stop mongod
sudo rm -f /var/lib/mongodb              # this is the symlink, not the data

# purge packages + repo/config/logs (data on /data is NOT touched)
sudo apt-get purge -y 'mongodb-org*'
sudo apt-get autoremove --purge -y
sudo rm -rf /var/log/mongodb /etc/mongod.conf
sudo rm -f /etc/apt/sources.list.d/mongodb-org-7.0.list /etc/apt/keyrings/mongodb-7.0.gpg
sudo apt-get update -y

# full wipe — ALSO delete the data (irreversible)
sudo rm -rf /data/mongodb
```

## Notes

- **Browser UI:** none — MongoDB ships no native web console; `mongosh` is the CLI. `mongo-express` is a
  Docker-only companion (out of scope for this native variant).
- Data lives under `/data/mongodb` (symlinked from `/var/lib/mongodb`); install/uninstall never touch a
  sibling service's data under `/data`.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../03_docker_single/` — the Docker Compose single-node variant.
- `../../../dependencies/03_Databases_datastores/05_MongoDB_8.0/` — the original install scripts + the
  canonical manual-install / testing reference these commands mirror (note: deps pins **8.0**/`noble` for
  AL2023-class hosts; this utility pins **7.0**/`jammy` because of the kernel-7.0 crashloop).
