# Neo4j — native single-node (no Docker, Community)

Neo4j 2026.x **Community** installed from the official Neo4j apt repo, run by **systemd**, data under
**`/data/neo4j`** (symlinked from `/var/lib/neo4j/data`), HTTP `:7474` (built-in **Neo4j Browser** UI),
Bolt `:7687`. Install is **non-destructive** (existing `/data` is reused, never wiped); uninstall **keeps
the data**.

- **What runs:** the `neo4j` package (Community, GPLv3 — `cypher-shell` is bundled with it).
- **Data:** `${DATA_ROOT}/neo4j` (default `/data/neo4j`), symlinked from `/var/lib/neo4j/data`.
- **Browser UI:** the built-in **Neo4j Browser** at `http://<host>:7474` (log in with the creds).
- **Community = single-node, no clustering.** For HA use `04_docker_cluster` (3-primary Enterprise eval).

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (generates a complex password, prints a credentials summary); and **B. Manual** — raw
copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit ports / bind address / a fixed password
```

`.env` is gitignored (it holds the real password); only `.env.example` is committed. Key vars:
`NEO4J_USER`, `NEO4J_PASSWORD`, `NEO4J_HTTP_PORT`, `NEO4J_BOLT_PORT`, `NEO4J_LISTEN_ADDRESS`, `DATA_ROOT`.
**Leave `NEO4J_PASSWORD` empty to auto-generate a complex (24-char) password on install** — Neo4j requires
`>= 8` chars; it is shown once and saved back to `.env`. With the script you can skip the edit entirely and
pass the password as a flag; with the manual path you choose the password yourself in the commands below.

## Install

### A. Scripted install (recommended)

```bash
sudo bash setup.sh install                        # auto-generates a complex password
sudo bash setup.sh install --password 'mypass8+'  # fixed password (>= 8 chars; else a 24-char one is generated)
sudo bash setup.sh install --gen-password         # force a fresh generated password (fresh DB only — see note)
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks) and ends with a **credentials summary** — HTTP /
Browser URL, Bolt endpoint, user, password, connection URL, and a `cypher-shell` smoke command. The password
is **shown once** and persisted to `.env` (chmod 600). Idempotent: resolves the creds, adds the Neo4j apt
repo + installs Community, points the data dir at `/data/neo4j`, applies the listen/port config, sets the
**initial** password, starts the service, and verifies `RETURN 1`. **A no-flag re-run reuses the stored
password.**

> **Initial-password caveat (Neo4j ≠ PostgreSQL).** `neo4j-admin dbms set-initial-password` only takes on a
> **never-started** database. On an already-initialised graph the install **reuses** the existing password
> (it cannot rotate it). To change the password on a live graph, log in and run
> `ALTER CURRENT USER SET PASSWORD FROM '<old>' TO '<new>'`, or `purge` and re-create.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. Choose your own
password where shown. **Order matters:** install the package *first* (it creates the `neo4j` user,
`/var/lib/neo4j`, and `/etc/neo4j/neo4j.conf`), *then* repoint the data dir, *then* set the initial password
**before the first start**.

```bash
# 1. trust the Neo4j signing key + add the official apt repo (Community on the `latest` channel)
sudo apt-get update -y
sudo apt-get install -y wget gnupg curl ca-certificates apt-transport-https
sudo mkdir -p /etc/apt/keyrings
wget -qO- https://debian.neo4j.com/neotechnology.gpg.key | sudo gpg --batch --yes --dearmor -o /etc/apt/keyrings/neo4j.gpg
echo "deb [signed-by=/etc/apt/keyrings/neo4j.gpg] https://debian.neo4j.com stable latest" | sudo tee /etc/apt/sources.list.d/neo4j.list

# 2. install Neo4j Community (creates the `neo4j` user + /var/lib/neo4j + /etc/neo4j; cypher-shell is bundled)
sudo apt-get update -y
sudo apt-get install -y neo4j

# 3. point the data dir at /data BEFORE the first start (stop first; the symlink target is the `data` SUBDIR)
sudo systemctl stop neo4j 2>/dev/null || true
sudo mkdir -p /data/neo4j
# preserve any data the package laid down, then symlink /var/lib/neo4j/data -> /data/neo4j (non-destructive)
[ -d /var/lib/neo4j/data ] && sudo cp -a /var/lib/neo4j/data/. /data/neo4j/ 2>/dev/null || true
sudo rm -rf /var/lib/neo4j/data && sudo ln -sfn /data/neo4j /var/lib/neo4j/data
sudo chown -R neo4j:neo4j /data/neo4j /var/lib/neo4j/data

# 4. set the listen address + HTTP/Bolt ports (these keys override neo4j.conf; default bind 0.0.0.0)
CONF=/etc/neo4j/neo4j.conf
sudo sed -i -E '/^#?\s*(server\.default_listen_address|server\.bolt\.listen_address|server\.http\.listen_address|server\.bolt\.advertised_address|server\.http\.advertised_address)=/d' "$CONF"
printf 'server.default_listen_address=0.0.0.0\nserver.bolt.listen_address=0.0.0.0:7687\nserver.http.listen_address=0.0.0.0:7474\n' | sudo tee -a "$CONF" >/dev/null

# 5. set the INITIAL password (only works on a never-started DB) — pick your own (>= 8 chars)
sudo neo4j-admin dbms set-initial-password 'ChangeMe_StrongPassword'

# 6. enable + start the service
sudo systemctl enable --now neo4j

# 7. verify — service up, HTTP 200, and a Cypher RETURN 1 round-trip over the HTTP transaction API
# the JVM takes ~10-30s to bind the HTTP connector after start — POLL first (setup.sh loops here too),
# else an immediate curl/query returns 000 (connection refused) while Neo4j is still warming up
systemctl is-active neo4j                                            # -> active
until curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:7474/ | grep -qE '200|303'; do sleep 2; done
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7474/    # -> 200
curl -s -u neo4j:'ChangeMe_StrongPassword' -H 'content-type: application/json' \
  http://127.0.0.1:7474/db/neo4j/tx/commit -d '{"statements":[{"statement":"RETURN 1"}]}'   # -> "row":[1]
# (or with the bundled Bolt client)
cypher-shell -a bolt://127.0.0.1:7687 -u neo4j -p 'ChangeMe_StrongPassword' --non-interactive 'RETURN 1 AS ok;'
```

## Test

The shared contract/smoke test creates a throwaway labelled subgraph (nodes + a relationship, bilingual
UTF-8 props), reads it back, then `DETACH DELETE`s its own label and **proves zero residue**. Client: `curl`
against the HTTP transaction API (no host packages beyond curl needed).

### A. Scripted test (the shared contract test)

```bash
# from utility/13_Neo4j/  (auto-reads user + the generated password from 01_native_single/.env)
bash ../test.sh 01_native_single

# or pass the connection explicitly (use your actual password) — works cross-host too
NEO4J_HOST=<host> NEO4J_USER=neo4j NEO4J_PASSWORD='<your-password>' bash ../test.sh
```

Exits `0` and prints `RESULT: PASS` when every check passes and nothing is left behind.

### B. Manual test (raw write → read → clean-up)

Mirrors the contract test — create a uniquely labelled node with a UTF-8 property, read it back, then
`DETACH DELETE` it and confirm the count is `0` (zero residue). Uses its own `DokSmoke` label so it touches
nothing else.

```bash
H=127.0.0.1; P=7474; U=neo4j; PW='<your-password>'; T=http://$H:$P/db/neo4j/tx/commit
cy(){ curl -s -u "$U:$PW" -H 'content-type: application/json' "$T" -d "{\"statements\":[{\"statement\":\"$1\"}]}"; }

# write a node with a bilingual UTF-8 property
cy "CREATE (:DokSmoke {id:1, name:'চাল-rice'})"
# read it back (-> "row":["চাল-rice"])
cy "MATCH (n:DokSmoke {id:1}) RETURN n.name"
# clean up + prove zero residue (-> "row":[0])
cy "MATCH (n:DokSmoke) DETACH DELETE n"
cy "MATCH (n:DokSmoke) RETURN count(n)"
```

## Status

```bash
sudo bash setup.sh status        # service + HTTP 200 + RETURN 1 query + data-dir size
# manual equivalent:
systemctl is-active neo4j && curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:7474/
```

## Uninstall

### A. Scripted uninstall

Removes the package, config, and repo but **keeps the data** at `/data/neo4j`:

```bash
sudo bash setup.sh uninstall     # package + /etc/neo4j + repo/keyring removed; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/neo4j and /var/lib/neo4j (full wipe)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + disable, then purge the package (cypher-shell is bundled with neo4j — no separate purge)
sudo systemctl stop neo4j
sudo systemctl disable neo4j
sudo apt-get purge -y neo4j
sudo apt-get autoremove --purge -y

# remove config + the apt repo/keyring (data on /data is NOT touched)
sudo rm -rf /etc/neo4j
sudo rm -f /etc/apt/sources.list.d/neo4j.list /etc/apt/keyrings/neo4j.gpg
sudo apt-get update -y

# full wipe — ALSO delete the data + the symlink target (irreversible)
sudo rm -rf /data/neo4j /var/lib/neo4j
```

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../03_docker_single/` — the Docker single-node (Community) variant.
- `../04_docker_cluster/` — the 3-primary Enterprise-eval HA cluster.
- `../../../dependencies/03_Databases_datastores/09_Neo4j_2026.x/` — the original install scripts + the
  canonical manual-install / GDS-plugin reference these commands mirror.
