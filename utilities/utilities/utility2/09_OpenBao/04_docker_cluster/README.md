# OpenBao 2.x — Docker Compose HA cluster (3-node integrated Raft)

Three `openbao/openbao` containers forming a single **integrated-Raft** quorum (OpenBao's built-in
storage — no external datastore). One node is the Raft **leader**, the other two are voting followers;
every secret is **replicated to all three**. `setup.sh` initialises node 1, unseals all three with the one
dev key, joins 2 + 3 into the quorum, and enables a **KV v2** engine. The built-in web UI is on
`:8200/ui` of any node.

```text
        client API (writes -> leader; reads any node)
              │
   ┌──────────┼─────────────────────────────────────┐
   ▼          ▼                                       ▼
┌────────┐ ┌────────┐ ┌────────┐
│ bao-1  │ │ bao-2  │ │ bao-3  │      one Raft quorum (KV v2 replicated to all 3)
│ :8200  │ │ :8202  │ │ :8203  │      host API ports →  each container listens on :8200
│ leader │ │follower│ │follower│      Raft cluster traffic is internal :8201
└────────┘ └────────┘ └────────┘
   └── retry_join ──┴── retry_join ──┘   (bao-1 / bao-2 / bao-3 by compose service name)
```

**One** unseal key unseals **all three** nodes (1 key / threshold 1 is a **dev** convenience). Per-node
Raft data are **host bind mounts** and survive `docker compose down -v`.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(initialises node 1, unseals + joins all three, enables KV v2, verifies 3/3 peers, prints a connection
summary); and **B. Manual** — raw `docker compose` + `curl` commands.

## How it works (and why the data survives `down -v`)

- Each node stores its Raft data on a **host bind mount** at `/openbao/data`:
  `${DATA_ROOT}/openbao_cluster/{n1,n2,n3}`. There is **no named volume**, so `docker compose down -v`
  keeps all three nodes' state; the next `up` re-unseals with the saved key and the quorum re-forms.
- Each node's config (`bao-1.hcl` / `bao-2.hcl` / `bao-3.hcl`) declares `storage "raft"` with its own
  `node_id` and three `retry_join` stanzas (one per node, by compose service name `bao-1`/`bao-2`/`bao-3`),
  so the nodes find each other over the bridge network. `cluster_addr`/`api_addr` use the service names.
- **Cluster formation is automatic on `up`:** node 1 is initialised once, all three are unsealed with the
  same key, and nodes 2 + 3 `retry_join` node 1 into the quorum. There is no separate `raft join` command
  to run — unsealing a follower with the shared key joins it.

> Nodes run as **root** with `entrypoint: ["bao"]` (`user: "0:0"`, `cap_add: [IPC_LOCK]`), bypassing the
> privilege-dropping image entrypoint, so each root-owned bind-mounted Raft data dir is writable.

## Prerequisites

Docker Engine + the Compose plugin (see `../03_docker_single/README.md` for the install). The contract
test + acceptance talk to the API over `curl` (or a `curlimages/curl` container) — no extra client package
is needed.

## Configure

```bash
cp .env.example .env        # set host ports if 8200/8202/8203 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `BAO_VERSION` (image tag, default
`2.5.4`), the host API ports `BAO_PORT1` / `BAO_PORT2` / `BAO_PORT3` (default `8200` / `8202` / `8203`;
each container listens on `8200`, Raft cluster traffic is internal `:8201`), and `DATA_ROOT`. **If
`8200`/`8202`/`8203` are taken** (e.g. a native or single-node OpenBao is already running), change them.
**`BAO_ROOT_TOKEN` and `BAO_UNSEAL_KEY` are written by `setup.sh up` after `operator init` — do not
pre-fill them.** As with the single-node variant, OpenBao needs **no password in `.env` before `up`** —
the root token + unseal key are *generated* by the init step.

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up
```

`setup.sh up` prints **numbered step output** (1/5 … 5/5): per-node data dirs + `docker compose up` (3
nodes) → **initialise node 1** (idempotent — reuses `.env` token/key if already initialised) → **unseal
node 1** (the leader) → **unseal + join nodes 2 + 3** (they `retry_join` into the quorum) → enable **KV
v2** at `secret/` + verify **3/3 Raft peers**. The root token + the single unseal key are saved to `.env`
(chmod 600) and the root token is **shown once** in the **connection summary** (per-node endpoints,
`:8200/ui` URL, token, unseal key, host data dirs). A no-flag re-run reuses the stored token/key.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file (no password needed — OpenBao generates its own token + unseal key on init)
cp .env.example .env

# 2. create the three per-node bind-mount data dirs
sudo mkdir -p /data/openbao_cluster/n1 /data/openbao_cluster/n2 /data/openbao_cluster/n3

# 3. bring all three nodes up (they retry_join by service name once unsealed)
docker compose up -d
until curl -s --max-time 3 'http://localhost:8200/v1/sys/health?uninitcode=200&sealedcode=200' >/dev/null; do sleep 2; done

# 4. initialise NODE 1 only (1 key / threshold 1 — DEV) + capture the root token + unseal key
INIT=$(curl -s -X PUT http://localhost:8200/v1/sys/init -d '{"secret_shares":1,"secret_threshold":1}')
ROOT_TOKEN=$(printf '%s' "$INIT" | python3 -c "import sys,json;print(json.load(sys.stdin)['root_token'])")
UNSEAL_KEY=$(printf '%s' "$INIT" | python3 -c "import sys,json;print(json.load(sys.stdin)['keys_base64'][0])")
echo "ROOT TOKEN : $ROOT_TOKEN"     # save these OUT OF BAND (and into .env to let setup.sh reuse them)
echo "UNSEAL KEY : $UNSEAL_KEY"

# 5a. unseal NODE 1 first (the leader) and let it settle
curl -s -X PUT http://localhost:8200/v1/sys/unseal -d "{\"key\":\"${UNSEAL_KEY}\"}" >/dev/null
sleep 3

# 5b. unseal nodes 2 + 3 with the SAME key (this joins them into the Raft quorum). Followers boot
#     UNINITIALISED and must finish retry_join against the unsealed leader before /sys/unseal succeeds,
#     so RETRY each until it reports sealed=false (a single attempt is too early — it stays sealed).
sealed(){ curl -s "http://localhost:$1/v1/sys/health?uninitcode=200&sealedcode=200&standbycode=200" | python3 -c "import sys,json;print(json.load(sys.stdin)['sealed'])"; }
for p in 8202 8203; do
  for _ in $(seq 1 15); do
    curl -s -X PUT http://localhost:$p/v1/sys/unseal -d "{\"key\":\"${UNSEAL_KEY}\"}" >/dev/null
    [ "$(sealed $p)" = "False" ] && break
    sleep 2
  done
done

# 6. enable a KV v2 engine at secret/ (on the leader; Raft replicates it)
curl -s -X POST -H "X-Vault-Token: ${ROOT_TOKEN}" http://localhost:8200/v1/sys/mounts/secret \
  -d '{"type":"kv","options":{"version":"2"}}' >/dev/null

# 7. verify 3 Raft voters
docker compose ps
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" http://localhost:8200/v1/sys/storage/raft/configuration \
  | grep -oE '"node_id":"bao-[123]"' | wc -l        # -> 3
```

> **Persist the credentials.** Write `BAO_ROOT_TOKEN=<root-token>` and `BAO_UNSEAL_KEY=<unseal-key>` into
> `.env` (`chmod 600 .env`) so a later `setup.sh up` reuses them. Treat both as secrets. If non-default
> host ports are used, adjust the `http://localhost:<port>` URLs above.

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh acceptance
```

Runs the two HA criteria: the leader's Raft configuration shows **3 voters**, and a secret **written on
node 1 (`:8200`) is read back via node 2 (`:8202`)** — proving Raft replication. Cleans up the probe
secret afterwards.

### B. Manual acceptance (write on node 1 → read on node 2 → assert replicated)

```bash
T=<root-token>

# (1) Raft quorum has 3 voters
curl -s -H "X-Vault-Token: $T" http://localhost:8200/v1/sys/storage/raft/configuration \
  | grep -oE '"node_id":"bao-[123]"' | wc -l        # -> 3

# (2) write on NODE 1 (the leader)
curl -s -H "X-Vault-Token: $T" -X POST http://localhost:8200/v1/secret/data/ha_check \
  -d '{"data":{"v":"replicated-চাল"}}' >/dev/null
sleep 1

# read it back via NODE 2 (proves Raft replication across nodes)
curl -s -H "X-Vault-Token: $T" http://localhost:8202/v1/secret/data/ha_check \
  | grep -o 'replicated-চাল'                         # -> replicated-চাল

# clean up the probe secret
curl -s -H "X-Vault-Token: $T" -X DELETE http://localhost:8200/v1/secret/metadata/ha_check >/dev/null
```

## Test (the shared contract test, via node 1)

The shared contract test confirms the cluster is **initialised + unsealed**, writes a throwaway KV v2
secret (bilingual UTF-8 `চাল-rice`) via node 1, reads it back, then destroys it and proves zero residue
(read → 404).

### A. Scripted test

```bash
# from utility/09_OpenBao/
bash test.sh 04_docker_cluster

# cross-host (use node 1's published port + the root token):
BAO_HOST=<host> BAO_API_PORT=8200 BAO_TOKEN=<root-token> bash test.sh
```

### B. Manual test (raw write → read → clean-up via node 1)

```bash
T=<root-token>; P=dokandar_smoke

# write a KV v2 secret (bilingual UTF-8) → read it back (via node 1)
curl -s -H "X-Vault-Token: $T" -X POST http://localhost:8200/v1/secret/data/$P \
  -d '{"data":{"name":"চাল-rice","qty":"100"}}' >/dev/null
curl -s -H "X-Vault-Token: $T" http://localhost:8200/v1/secret/data/$P     # -> "name":"চাল-rice","qty":"100"

# destroy it + PROVE zero residue (read -> 404)
curl -s -H "X-Vault-Token: $T" -X DELETE http://localhost:8200/v1/secret/metadata/$P >/dev/null
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $T" http://localhost:8200/v1/secret/data/$P   # -> 404
```

## Connection model

- **Writes → the leader.** Clients hit any node's API (`:8200`/`:8202`/`:8203`); OpenBao forwards writes to
  the Raft leader internally, so use node 1's published port (`:8200`) as the primary endpoint.
- **Reads → any node** — standbys forward client requests to the leader, and every secret is
  Raft-replicated to all three, so a read via node 2 or 3 returns node 1's write (the acceptance check
  above proves it).

## Data persistence / teardown

Each node's Raft data is a **host bind mount** under `${DATA_ROOT}/openbao_cluster/n{1,2,3}`, so
`down`/`down -v` keep the quorum state; the next `up` re-unseals with the saved key. Only `purge` deletes
all three data dirs (secrets gone).

## Status / logs

```bash
bash setup.sh status        # docker compose ps + host data size
bash setup.sh logs          # follow all 3 nodes' logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data (Raft + seal) PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/openbao_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the three per-node data dirs (secrets + seal, irreversible)
docker compose down -v
sudo rm -rf /data/openbao_cluster
```

## Notes

- **Browser UI:** the built-in OpenBao UI at `http://<host>:8200/ui` on any node (`:8200` / `:8202` /
  `:8203`) — log in with the root token.
- Dev posture: TLS disabled, 1-key seal. Production = TLS between nodes, 5-of-3 Shamir or auto-unseal,
  odd-sized quorum (3 or 5) across AZs.

## See also

- `../README.md` — using `test.sh` across all variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../03_docker_single/` — the Docker Compose single-node variant.
- `../../../dependencies/08_Edge_secrets_frontend/01_OpenBao_2.x/cluster_mode/` — the native (no-Docker) HA
  reference this mirrors.
