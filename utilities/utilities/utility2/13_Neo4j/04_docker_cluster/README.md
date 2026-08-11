# Neo4j — Docker Compose HA cluster (3 primaries, Enterprise EVAL)

Three `neo4j:2026.05.0-enterprise` containers forming **one autonomous cluster of 3 PRIMARY servers**
(Raft). Writes go to the elected **leader** (and are **server-side routed** there from any node), every
primary holds a **full copy**, and quorum (2 of 3) tolerates one node loss. Tested on Ubuntu 26.04 (local +
cross-host on AWS).

```text
        writes (routed to the leader)        reads (any primary — full copy)
                    │                          ┌──────────┬──────────┐
                    ▼                          ▼          ▼          ▼
            ┌────────────┐    Raft     ┌────────────┐ ┌────────────┐ ┌────────────┐
            │   neo4j1   │◄──────────► │   neo4j1   │ │   neo4j2   │ │   neo4j3   │
            │ HTTP :7474 │  (quorum    │ HTTP :7474 │ │ HTTP :7475 │ │ HTTP :7476 │
            │ Bolt :7687 │   2 of 3)   │ Bolt :7687 │ │ Bolt :7688 │ │ Bolt :7689 │
            └────────────┘             └────────────┘ └────────────┘ └────────────┘
              discovery :6000 (LIST: neo4j1/2/3) · raft :7000   (container-internal)
```

> **Licence.** This uses Neo4j **Enterprise** under the **EVALUATION** licence
> (`NEO4J_ACCEPT_LICENSE_AGREEMENT=eval`) — a deliberate choice to make the HA cluster **testable**.
> **Eval is dev/test only — NOT a production licence.** Neo4j Community is single-node by design;
> autonomous/Causal clustering is Enterprise-only.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the password, brings up the 3 primaries, runs the acceptance gate, prints a credentials summary);
and **B. Manual** — raw `docker compose` + Ubuntu commands.

## How it works (cluster formation is automatic on `up`)

- All 3 services are **PRIMARY** (read-write); they form one Raft group via **LIST discovery** —
  `NEO4J_dbms_cluster_endpoints: neo4j1:6000,neo4j2:6000,neo4j3:6000` (resolved by each service's
  `hostname:`). Discovery listens on `:6000`, raft on `:7000` (both container-internal). **There is no
  manual cluster-init / `docker compose exec` step — the cluster self-forms when the 3 containers start.**
- Each node differs **only** in `server.default_advertised_address` (`neo4j1/2/3`); every other advertised
  port derives from it. Heap is capped at `512m`/node + `512m` pagecache so 3 servers fit a ~6.4 GB box.
- **Writes** go to whichever node is the elected **leader** — a Bolt `neo4j://` routing driver finds it
  automatically; over raw HTTP you post the write to each node until one returns `"errors":[]` (that is the
  leader). **Reads** can hit any primary (each holds a full replicated copy).

### Why the data survives `down -v`

Each primary's data is a **host bind mount** at the image's `/data` path
(`${DATA_ROOT}/neo4j_cluster/n{1,2,3}`). There is **no named volume**, so:

| Command | Containers | Data (`${DATA_ROOT}/neo4j_cluster`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** (all 3 nodes + Raft state) |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** — the cluster re-forms from them |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

The image runs as uid `7474`; `setup.sh` (and the manual path) chown the bind dirs to `7474:7474`.

## Prerequisites

Docker Engine + Compose plugin (see `../03_docker_single/README.md` for the install). The shared `test.sh`
and `setup.sh accept` only need `curl` (they fall back to a `curlimages/curl` container if curl is absent),
so no Neo4j client packages are required on the host.

## Configure

```bash
cp .env.example .env        # set host ports if 7474–7476 / 7687–7689 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `NEO4J_IMAGE`, `NEO4J_USER`,
`NEO4J_PASSWORD`, the three HTTP host ports `N_HTTP1`/`N_HTTP2`/`N_HTTP3` (→ each container's 7474) and the
three Bolt host ports `N_BOLT1`/`N_BOLT2`/`N_BOLT3` (→ each container's 7687), and `DATA_ROOT`. **Leave
`NEO4J_PASSWORD` empty to auto-generate a complex (24-char) password** — `setup.sh up` fills it (identical
on all 3 primaries) before `docker compose up`. **A direct `docker compose up` needs `NEO4J_PASSWORD` set
non-empty in `.env`** — the compose file has `NEO4J_AUTH: neo4j/${NEO4J_PASSWORD:?set in .env}` and refuses
to start without it — so the manual path sets it explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                 # generates the password, brings up 3 primaries, runs the acceptance gate
bash setup.sh up --password 'mypass8+'   # set the password explicitly (>= 8 chars)
bash setup.sh up --gen-password          # generate a fresh password (FIRST init only — see note)
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3 + acceptance): resolves the creds, creates +
chowns the per-node data dirs, `docker compose up -d` (Enterprise startup is slow), waits for each node's
HTTP, verifies **3-server** membership (`SHOW SERVERS`), then runs the **acceptance gate**. It ends with a
**credentials summary** (all 3 HTTP/Browser + Bolt endpoints, user, password, the eval-licence note); the
password is shown once and saved to `.env`. A no-flag re-run reuses it.

> **`NEO4J_AUTH` applies only at first init (Neo4j ≠ PostgreSQL).** The password is honoured **only when a
> node's data dir is empty**, and is set identically on all 3 primaries on the first `up`. There is no live
> rotation step, so `--gen-password` / `--password` only take effect on a **fresh** cluster (or after
> `purge`). To change it on a running cluster, log in via the leader and run
> `ALTER CURRENT USER SET PASSWORD FROM '<old>' TO '<new>'` (it replicates), or `purge` and re-create.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose refuses an empty NEO4J_PASSWORD — `${...:?set in .env}`)
cp .env.example .env
sed -i "s/^NEO4J_PASSWORD=.*/NEO4J_PASSWORD=ChangeMe_StrongPassword/" .env

# 2. create + chown the three per-node host bind-mount data dirs (the image runs as uid 7474)
sudo mkdir -p /data/neo4j_cluster/n1 /data/neo4j_cluster/n2 /data/neo4j_cluster/n3
sudo chown -R 7474:7474 /data/neo4j_cluster

# 3. bring up all 3 primaries (they self-form one Raft group via LIST discovery — NO manual init step)
docker compose up -d

# 4. wait until all 3 nodes answer HTTP, then confirm 3-server membership (Enterprise startup is slow)
watch -n3 'docker compose ps'   # Ctrl-C once neo4j1/neo4j2/neo4j3 are all "Up"
# Raft formation lags container start — POLL until SHOW SERVERS reports 3 (do_up loops here too); a single
# immediate query can return "row":[1]/[2] before the cluster finishes forming. PW must match step 1's .env.
membership(){ curl -s -u neo4j:'ChangeMe_StrongPassword' -H 'content-type: application/json' \
  http://127.0.0.1:7474/db/neo4j/tx/commit \
  -d '{"statements":[{"statement":"SHOW SERVERS YIELD name RETURN count(name)"}]}'; }
until membership | grep -q '"row":\[3\]'; do sleep 3; done
membership   # -> "row":[3]
```

Open the **Neo4j Browser** at `http://<host>:7474` (or `:7475` / `:7476`) on any node — the same replicated
graph appears everywhere.

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh accept        # also run automatically at the end of `setup.sh up`
```

Runs the 3 criteria below and cleans up after itself (its own `HaCheck_*` label).

### B. Manual acceptance (3 servers · write-leader/read-all-3 · follower-down failover)

These mirror `do_accept` exactly. The helper posts a statement to whichever node is the leader (loops the 3
HTTP ports until one returns `"errors":[]`).

```bash
PW='<your-password>'
cy(){ curl -s -u "neo4j:$PW" -H 'content-type: application/json' "http://127.0.0.1:$1/db/neo4j/tx/commit" -d "{\"statements\":[{\"statement\":\"$2\"}]}"; }
write_leader(){ for p in 7474 7475 7476; do cy "$p" "$1" | grep -q '"errors":\[\]' && { echo "$p"; return 0; }; done; return 1; }

# (1) the cluster has 3 servers
cy 7474 "SHOW SERVERS YIELD name RETURN count(name)"                 # -> "row":[3]

# (2) write via the LEADER, read it back on ALL 3 primaries (replication), UTF-8 intact
# the `neo4j` database is onlined a beat AFTER the 3 servers join; wait for it to be queryable on some
# node before the first write (a single immediate pass can spuriously miss the leader — do_accept loops too)
until cy 7474 "RETURN 1" | grep -q '"row":\[1\]' || cy 7475 "RETURN 1" | grep -q '"row":\[1\]' || cy 7476 "RETURN 1" | grep -q '"row":\[1\]'; do sleep 3; done
write_leader "CREATE (:HaCheck {id:1, name:'চাল-rice'})"             # prints the leader's HTTP port
for p in 7474 7475 7476; do cy "$p" "MATCH (n:HaCheck) RETURN count(n)"; done   # each -> "row":[1]
cy 7475 "MATCH (n:HaCheck {id:1}) RETURN n.name"                     # -> "row":["চাল-rice"]

# (3) failover: stop neo4j3, a write is still accepted (quorum 2/3), survivors serve the full data
docker compose stop neo4j3 && sleep 6
# if neo4j3 was the leader, re-election takes a few seconds — RETRY until a survivor accepts the write
# (do_accept loops ~30s here); a single pass after only 6s can silently no-op and leave the count at 1
until write_leader "CREATE (:HaCheck {id:2, name:'ডিম-egg'})" >/dev/null; do sleep 2; done   # re-election ok
cy 7474 "MATCH (n:HaCheck) RETURN count(n)"                          # survivor -> "row":[2]
# restart neo4j3 and POLL until it re-joins — Enterprise rejoin is slow (do_accept allows up to ~75s),
# so a fixed short sleep would still show "row":[2]; loop until SHOW SERVERS reports all 3 again
docker compose start neo4j3
until [ "$(cy 7474 "SHOW SERVERS YIELD name RETURN count(name)" | grep -oE '"row":\[[0-9]+\]')" = '"row":[3]' ]; do sleep 3; done
cy 7474 "SHOW SERVERS YIELD name RETURN count(name)"                 # neo4j3 rejoined -> "row":[3]

# clean up (zero residue)
write_leader "MATCH (n:HaCheck) DETACH DELETE n"
```

## Test (the shared contract test, via any node)

### A. Scripted test

```bash
# from utility/13_Neo4j/  (writes are server-side routed to the leader, so any node works)
bash ../test.sh 04_docker_cluster

# or explicitly against a chosen node's HTTP port
NEO4J_HOST=<host> NEO4J_HTTP_PORT=7474 NEO4J_USER=neo4j NEO4J_PASSWORD='<your-password>' bash ../test.sh
```

Creates a throwaway labelled subgraph, reads it back, then `DETACH DELETE`s its own label and proves zero
residue.

### B. Manual test (raw write → read → clean-up)

```bash
PW='<your-password>'; T=http://127.0.0.1:7474/db/neo4j/tx/commit
cy(){ curl -s -u "neo4j:$PW" -H 'content-type: application/json' "$T" -d "{\"statements\":[{\"statement\":\"$1\"}]}"; }

cy "CREATE (:DokSmoke {id:1, name:'চাল-rice'})"      # write (routed to the leader)
cy "MATCH (n:DokSmoke {id:1}) RETURN n.name"         # read back -> "row":["চাল-rice"]
cy "MATCH (n:DokSmoke) DETACH DELETE n"              # clean up
cy "MATCH (n:DokSmoke) RETURN count(n)"              # prove zero residue -> "row":[0]
```

## Connection model

- **Writes → the elected leader.** A Bolt routing driver (`neo4j://<host>:7687`) discovers and targets the
  leader automatically; over raw HTTP, post the write to each node until one returns `"errors":[]`.
- **Reads → any primary** (`:7474` / `:7475` / `:7476` HTTP, `:7687` / `:7688` / `:7689` Bolt) — each holds
  a full replicated copy.

## Status / logs

```bash
bash setup.sh status        # compose ps + per-node HTTP check + host data size
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/neo4j_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mounts survive -v

# full wipe — ALSO delete the three host data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/neo4j_cluster
```

## Notes

- **Browser UI:** `http://<host>:7474` (or `:7475` / `:7476`) on any node — same replicated data everywhere.
- **Memory:** heap is capped at `512m`/node + `512m` pagecache so 3 servers fit a ~6.4 GB box —
  `minimum_initial_system_primaries_count=3` is all-or-nothing, so an OOM-kill of one node would stall the
  whole cluster. Raise the heap on bigger hosts.
- Production HA would use a **commercial Enterprise licence**, dedicated hosts/AZs per primary, and TLS.

## See also

- `../README.md` — using `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native (Community) variant.
- `../03_docker_single/` — the Docker single-node (Community) variant.
