# RabbitMQ 4.x — Docker Compose, single-node

One `rabbitmq:4-management` container (RabbitMQ 4.3.x with the **Management UI**), auth ON, run via Docker
Compose, configured from `.env`, with data on a **host bind mount** so it **survives `docker compose down
-v`**, `restart: always`. A **fixed `hostname`** keeps the mnesia dir (`rabbit@<hostname>`) stable across
restarts so the data is actually reused. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (generates a complex password, waits for the healthcheck, verifies/rotates the password via
`rabbitmqctl`, prints a credentials summary); and **B. Manual** — raw `docker compose` + Ubuntu commands
(create the env + data dir and bring it up by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores the broker's mnesia store on a bind mount
(`${DATA_ROOT}/rabbitmq_docker` → the image's `/var/lib/rabbitmq`) and declares **no named volume at all**,
and the container uses a **fixed `hostname`** (`dokandar-rabbit`) so the nodename-keyed data dir
(`rabbit@dokandar-rabbit`) is reused on every restart:

| Command | Container | Data (`${DATA_ROOT}/rabbitmq_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (queues/users exactly as left) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same data (verified live: a marker queue created before `down -v` is
still present after the next `up`). The *only* way to delete the data is `setup.sh purge` (or
`rm -rf ${DATA_ROOT}/rabbitmq_docker` by hand).

## Prerequisites — install Docker (one time)

Docker isn't in the Ubuntu base repo. Install Docker Engine + the Compose plugin from Docker's official
repo (on Ubuntu 26.04 "resolute", which Docker may not publish yet, point the repo at `noble`):

```bash
sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg
CODENAME=$(. /etc/os-release; echo "$VERSION_CODENAME")
curl -fsI "https://download.docker.com/linux/ubuntu/dists/${CODENAME}/Release" >/dev/null 2>&1 || CODENAME=noble
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu ${CODENAME} stable" | sudo tee /etc/apt/sources.list.d/docker.list
sudo apt-get update && sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
```

The shared `test.sh` needs only `curl` (host) — it falls back to a `curlimages/curl` container if `curl`
isn't on the host, so no extra client is required.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host ports / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `RABBITMQ_IMAGE_TAG` (default
`4-management`), `RABBITMQ_DEFAULT_USER`, `RABBITMQ_DEFAULT_PASS`, `RABBITMQ_AMQP_PORT` (host → container
5672), `RABBITMQ_MGMT_PORT` (host → container 15672), `DATA_ROOT`. **Leave `RABBITMQ_DEFAULT_PASS` empty to
auto-generate a complex (24-char) password** — `setup.sh up` fills it before `docker compose up`, shows it
once, and saves it back to `.env`. **A direct `docker compose up` needs a non-empty `RABBITMQ_DEFAULT_PASS`
in `.env`** (the compose file declares it `:?` required, and the image refuses to seed an empty admin
password), so the manual path sets one explicitly. If a native RabbitMQ already holds `5672`/`15672`, set
different `RABBITMQ_AMQP_PORT`/`RABBITMQ_MGMT_PORT` (e.g. `5673`/`15673`).

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                              # auto-generates a complex password
bash setup.sh up --user appuser               # name the admin role (first init)
bash setup.sh up --password 'MyOwnSecret'     # or set the password explicitly
bash setup.sh up --gen-password               # rotate to a fresh generated password
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3), creates + `chown`s the bind dir to uid 999
(the image's `rabbitmq` user), runs `docker compose up -d`, waits for the healthcheck, then
**verifies/rotates the admin password via `rabbitmqctl`** inside the container — so it works on a fresh
*or* existing cluster, and `--gen-password` rotates the live password. It ends with a **credentials
summary** (AMQP endpoint, user, password, AMQP URL, browser-UI URL); the password is shown once and saved
to `.env`. A no-flag re-run **reuses** the stored password.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET A PASSWORD (compose declares RABBITMQ_DEFAULT_PASS required)
cp .env.example .env
sed -i "s/^RABBITMQ_DEFAULT_PASS=.*/RABBITMQ_DEFAULT_PASS=ChangeMe_StrongPassword/" .env

# 2. create the host bind-mount data dir and give it to the image's rabbitmq user (uid 999)
sudo mkdir -p /data/rabbitmq_docker
sudo chown -R 999:999 /data/rabbitmq_docker

# 3. bring it up (reads .env for image tag, ports, user, password)
docker compose up -d

# 4. wait until healthy, then verify
for _ in $(seq 1 45); do [ "$(docker inspect -f '{{.State.Health.Status}}' dokandar_rabbitmq_docker_single 2>/dev/null)" = healthy ] && break; sleep 2; done
docker compose ps
docker compose exec -T rabbitmq rabbitmqctl authenticate_user dokandar 'ChangeMe_StrongPassword'   # -> Success
```

**Browser UI:** the Management plugin at `http://<host>:15672` (or your published `RABBITMQ_MGMT_PORT`) —
log in with the admin user from `.env`.

## Test

The shared contract test drives the Management HTTP API with `curl`: it creates a throwaway
`dokandar_rabbittest_<ts>` quorum queue, publishes a bilingual-UTF-8 message, reads it back, then deletes
the queue and proves zero residue.

### A. Scripted test

```bash
# from utility/06_RabbitMQ/  (auto-reads user + password from 03_docker_single/.env)
bash test.sh 03_docker_single

# or point it at the node by management URL (use your actual password / published mgmt port)
bash test.sh "http://dokandar:<your-password>@127.0.0.1:15672"
```

### B. Manual test (raw write → read → clean-up)

Drive the Management HTTP API with **host `curl`** against the published mgmt port (same as `test.sh` —
`B` uses your `RABBITMQ_MGMT_PORT`, default `15672`):

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

# delete the queue + prove zero residue
curl -s -u "$U:$P" -X DELETE "$B/api/queues/%2F/$Q"
curl -s -u "$U:$P" "$B/api/queues/%2F?columns=name" | grep -o 'dokandar_smoke' || echo 'clean: 0 test queues'
```

## Status / logs

```bash
bash setup.sh status        # docker compose ps + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/rabbitmq_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — bind mount survives -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/rabbitmq_docker
```

## Notes

- **Browser UI:** the Management plugin at `http://<host>:15672` (or your published mgmt port).
- A fixed `hostname` is essential: RabbitMQ keys its data dir by nodename (`rabbit@<hostname>`), so a
  changing hostname would orphan the data.

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the 3-node HA cluster variant.
