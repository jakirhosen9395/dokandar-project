# RabbitMQ 4.x — Docker Compose, HA cluster (3 nodes, quorum queues)

A 3-node RabbitMQ cluster via Docker Compose — **rabbit-1 / rabbit-2 / rabbit-3** — sharing one Erlang
cookie, with **quorum queues** (the 4.x default durable type) replicating across all three. Each node's
data is on its own **host bind mount** (survives `docker compose down -v`); fixed hostnames keep each
node's mnesia dir stable. Tested on Ubuntu 26.04.

## Topology

| Node | Container | hostname | Published ports |
| --- | --- | --- | --- |
| rabbit-1 | `dokandar_rabbit_1` | rabbit-1 | `5672` (AMQP) + `15672` (Management) |
| rabbit-2 | `dokandar_rabbit_2` | rabbit-2 | — (internal) |
| rabbit-3 | `dokandar_rabbit_3` | rabbit-3 | — (internal) |

```text
        clients (AMQP 5672 / Management 15672)
                      │
                      ▼
              ┌───────────────┐
              │   rabbit-1    │  published entry point
              │ rabbit@rabbit-1│
              └───────┬───────┘
        shared Erlang cookie · join_cluster
          ┌───────────┴───────────┐
          ▼                       ▼
   ┌───────────────┐       ┌───────────────┐
   │   rabbit-2    │       │   rabbit-3    │   (internal members)
   │ rabbit@rabbit-2│       │ rabbit@rabbit-3│   quorum queues replicate to all 3
   └───────────────┘       └───────────────┘
```

Clients connect to **node 1's** published AMQP/Management ports — the cluster is transparent (a quorum
queue is reachable and replicated regardless of which node you connect to). For real HA you would put a
load balancer in front of all three; here node 1 is the single published entry point.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — `setup.sh`
(generates the admin password + shared Erlang cookie, waits for 3 healthy nodes, joins nodes 2+3 to
node 1, prints a credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands.

## How it works (and why the data survives `down -v`)

- Each node stores its mnesia store on a **host bind mount** at the image's `/var/lib/rabbitmq`:
  `${DATA_ROOT}/rabbitmq_cluster/{n1,n2,n3}`. There is **no named volume**, so `docker compose down -v`
  keeps all three nodes' data and the cluster re-forms on the next `up`. Fixed hostnames
  (`rabbit-1/2/3`) keep each nodename-keyed data dir stable.
- The three nodes share one **Erlang cookie** (`RABBITMQ_ERLANG_COOKIE`) — that is what lets them
  authenticate to each other; it must be byte-identical on all three (compose injects it via the
  environment).
- **Clustering is NOT automatic on `up`.** The entrypoint only boots three standalone nodes; you then
  **join nodes 2 + 3 to `rabbit@rabbit-1`** with explicit `rabbitmqctl` commands (`stop_app` → `reset` →
  `join_cluster rabbit@rabbit-1` → `start_app`). `setup.sh up` runs this join step (idempotent — it skips
  a node already in the cluster); the manual path reproduces it below.

## Prerequisites

Docker Engine + Compose plugin (see `../03_docker_single/README.md` for the install). The shared `test.sh`
needs only `curl` (it falls back to a `curlimages/curl` container if `curl` isn't on the host).

## Configure

```bash
cp .env.example .env        # set host ports if 5672/15672 are taken; image tag / DATA_ROOT optional
```

`.env` is gitignored; only `.env.example` is committed. Key vars: `RABBITMQ_IMAGE_TAG` (default
`4-management`), `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, `RABBITMQ_ERLANG_COOKIE`,
`RABBITMQ_AMQP_PORT` / `RABBITMQ_MGMT_PORT` (node 1's published ports), `DATA_ROOT`. **Leave
`RABBITMQ_DEFAULT_PASS` and `RABBITMQ_ERLANG_COOKIE` empty to auto-generate them** — `setup.sh up` fills
both before forming the cluster. **A direct `docker compose up` needs BOTH set non-empty in `.env`** (the
compose file declares each `:?` required — the cookie is what lets the nodes cluster, and the image refuses
an empty admin password), so the manual path sets them explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                  # auto-generates the admin password + shared Erlang cookie
bash setup.sh up --password 'MyOwnSecret'   # or set the admin password explicitly
bash setup.sh up --gen-password   # rotate the admin password
```

`setup.sh up` prints **numbered step output** (1/4 … 4/4): configuration (password + cookie) → per-node
data dirs (`n1/n2/n3`, `chown`ed to uid 999) + `docker compose up -d` → wait for 3 healthy nodes →
**join nodes 2 + 3 to `rabbit@rabbit-1`** (idempotent), re-assert admin tags/permissions, print cluster
status. It ends with a **credentials summary** (AMQP endpoint, user, password, AMQP URL, browser-UI URL,
node list). Passwords/cookie are shown once and saved to `.env`; a no-flag re-run reuses them.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET BOTH the admin password AND the shared Erlang cookie (both required)
cp .env.example .env
sed -i "s/^RABBITMQ_DEFAULT_PASS=.*/RABBITMQ_DEFAULT_PASS=ChangeMe_StrongPassword/" .env
sed -i "s/^RABBITMQ_ERLANG_COOKIE=.*/RABBITMQ_ERLANG_COOKIE=ChangeMeClusterCookie2026/" .env   # alphanumeric ONLY (the cookie must be a string of alphanumeric chars; underscores/symbols can break Erlang distribution)

# 2. create the three per-node host bind-mount data dirs and give them to uid 999 (rabbitmq)
sudo mkdir -p /data/rabbitmq_cluster/n1 /data/rabbitmq_cluster/n2 /data/rabbitmq_cluster/n3
sudo chown -R 999:999 /data/rabbitmq_cluster

# 3. boot all 3 nodes (still standalone at this point — clustering is the next step)
docker compose up -d

# 4. wait until all 3 nodes report healthy
for _ in $(seq 1 60); do
  n=0; for c in dokandar_rabbit_1 dokandar_rabbit_2 dokandar_rabbit_3; do
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$c" 2>/dev/null)" = healthy ] && n=$((n+1)); done
  [ "$n" = 3 ] && break; sleep 3
done

# 5. JOIN nodes 2 + 3 to rabbit@rabbit-1 (this is the cluster-init the entrypoint does NOT do)
for svc in rabbit-2 rabbit-3; do
  docker compose exec -T "$svc" rabbitmqctl stop_app
  docker compose exec -T "$svc" rabbitmqctl reset
  docker compose exec -T "$svc" rabbitmqctl join_cluster rabbit@rabbit-1
  docker compose exec -T "$svc" rabbitmqctl start_app
done

# 6. re-assert the admin tag/permissions on node 1 + confirm 3 cluster members
docker compose exec -T rabbit-1 rabbitmqctl set_user_tags dokandar administrator
docker compose exec -T rabbit-1 rabbitmqctl set_permissions -p / dokandar ".*" ".*" ".*"
docker compose exec -T rabbit-1 rabbitmqctl cluster_status | grep -oE 'rabbit@rabbit-[123]' | sort -u   # -> 3 lines
```

**Browser UI:** the Management plugin at `http://<host>:15672` (node 1) — log in with the admin user.

## Verify the cluster (HA acceptance)

### A. Scripted acceptance

```bash
bash setup.sh acceptance
```

Runs the two criteria: **3 running nodes** (`rabbit@rabbit-1/2/3`), and a **quorum queue replicated to all
3 members**. It creates a throwaway `ha_check_<pid>` quorum queue, asserts its membership is 3, then
deletes it (cleans up after itself).

### B. Manual acceptance (create a quorum queue → assert it replicates to 3 members)

```bash
U=dokandar; P='ChangeMe_StrongPassword'; Q=ha_check_manual

# (1) the cluster has 3 running nodes
docker compose exec -T rabbit-1 rabbitmqctl cluster_status | grep -oE 'rabbit@rabbit-[123]' | sort -u   # -> 3 lines

# (2) create a quorum queue on node 1 and confirm it is replicated to all 3 members
curl -s -u "$U:$P" -H 'content-type: application/json' \
  -X PUT "http://localhost:15672/api/queues/%2F/$Q" -d '{"durable":true,"arguments":{"x-queue-type":"quorum"}}'
sleep 2
curl -s -u "$U:$P" "http://localhost:15672/api/queues/%2F/$Q" \
  | grep -oE 'rabbit@rabbit-[123]' | sort -u | wc -l        # -> 3  (replicated to 3 nodes)

# clean up
curl -s -u "$U:$P" -X DELETE "http://localhost:15672/api/queues/%2F/$Q"
```

## Test (the shared contract test, against the cluster)

### A. Scripted test

```bash
# from utility/06_RabbitMQ/  (reads 04_docker_cluster/.env → node 1's published mgmt port)
bash test.sh 04_docker_cluster

# or by management URL (use your actual password)
bash test.sh "http://dokandar:<your-password>@127.0.0.1:15672"
```

Creates a throwaway `dokandar_rabbittest_<ts>` quorum queue on node 1, exercises the full publish→get
round-trip (incl. the UTF-8 `চাল` payload), then deletes it and proves zero residue.

### B. Manual test (raw write → read → clean-up on node 1)

```bash
U=dokandar; P='ChangeMe_StrongPassword'; B=http://localhost:15672; Q=dokandar_smoke
curl -s -u "$U:$P" -H 'content-type: application/json' \
  -X PUT "$B/api/queues/%2F/$Q" -d '{"durable":true,"arguments":{"x-queue-type":"quorum"}}'
curl -s -u "$U:$P" -H 'content-type: application/json' \
  -X POST "$B/api/exchanges/%2F/amq.default/publish" \
  -d "{\"properties\":{},\"routing_key\":\"$Q\",\"payload\":\"chal-চাল-rice\",\"payload_encoding\":\"string\"}"
curl -s -u "$U:$P" -H 'content-type: application/json' \
  -X POST "$B/api/queues/%2F/$Q/get" \
  -d '{"count":1,"ackmode":"ack_requeue_false","encoding":"auto"}' | grep -o 'চাল'   # -> চাল
curl -s -u "$U:$P" -X DELETE "$B/api/queues/%2F/$Q"
curl -s -u "$U:$P" "$B/api/queues/%2F?columns=name" | grep -o 'dokandar_smoke' || echo 'clean: 0 test queues'
```

## Connection model

- **All clients → node 1** (`127.0.0.1:5672` AMQP, `:15672` Management). The cluster is transparent —
  quorum queues replicate to all three members, so a queue is reachable and durable regardless of the node
  it was declared on. For production HA, front all three with a load balancer.

## Status / logs

```bash
bash setup.sh status        # compose ps + host data size
bash setup.sh logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove all 3 containers — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/rabbitmq_cluster (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the containers — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the three per-node host data dirs (irreversible)
docker compose down -v
sudo rm -rf /data/rabbitmq_cluster
```

## Notes

- **Browser UI:** the Management plugin at `http://<host>:15672` (node 1).
- The shared **Erlang cookie** is what lets the nodes authenticate to each other — it must be
  byte-identical on all three (compose injects it via `RABBITMQ_ERLANG_COOKIE`).

## See also

- `../README.md` — using `test.sh` across all variants.
- `../03_docker_single/` — the single-node Docker variant (and the Docker-install prerequisites).
- `../01_native_single/` — the no-Docker, systemd-native variant.
