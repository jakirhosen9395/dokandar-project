# RustFS — Docker Compose single-node

One `rustfs/rustfs` container — **S3-compatible object storage** (replaces MinIO; the DOKANDAR object-store
exit path). Objects + logs on **host bind mounts** so they **survive `docker compose down -v`**, S3 API
`:9000`, built-in console `:9001`. Ported from the `dokandar/utilities/components` `rustfs/` reference.
Container runs as **uid 10001**. Tested on Ubuntu 26.04.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (auto-generates the S3 access (20 hex) + secret (40 hex) keys, brings the container up, waits for
the healthcheck, verifies the keys over the S3 API, prints a connection summary); and **B. Manual** — raw
`docker compose` + Ubuntu commands (create the env + data dirs and bring it up by hand). Both produce the
same container.

## Why the objects survive `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a **bind
mount** (a host directory). This compose file stores objects + logs on bind mounts
(`${DATA_ROOT}/rustfs_docker/data` → the container's `/data`, `${DATA_ROOT}/rustfs_docker/logs` → `/logs`)
and declares **no named volume at all**, so:

| Command | Container | Data (`${DATA_ROOT}/rustfs_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** (retained) |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same objects. The *only* way to delete them is `setup.sh purge` (or
`sudo rm -rf ${DATA_ROOT}/rustfs_docker` by hand).

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

The test + the manual verify use the `mc` S3 client, which runs in a throwaway `minio/mc` Docker container
— no host package needed.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit ports / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `RUSTFS_IMAGE`, `RUSTFS_ACCESS_KEY`,
`RUSTFS_SECRET_KEY`, `RUSTFS_API_PORT` (host → container 9000), `RUSTFS_CONSOLE_PORT` (→ 9001), `BIND_HOST`
(`0.0.0.0` exposes off-box, SG-fenced + key-gated; `127.0.0.1` = loopback only), the CORS allow-lists, and
`DATA_ROOT`. **Leave `RUSTFS_ACCESS_KEY`/`RUSTFS_SECRET_KEY` empty to auto-generate AWS-shape keys** —
`setup.sh up` fills them before `docker compose up`, shows them once, and saves them back to `.env`. **A
direct `docker compose up` needs both keys set non-empty in `.env`** (the compose file declares them
`:?set in .env`, so it refuses to start otherwise), so the manual path sets them explicitly.

## Install / up

### A. Scripted install (recommended)

```bash
bash setup.sh up                              # auto-generates the S3 access (20 hex) + secret (40 hex) keys
bash setup.sh up --gen-keys                   # rotate both keys
bash setup.sh up --access KEY --secret KEY    # set fixed keys explicitly
```

`setup.sh up` prints **numbered step output** (1/3 … 3/3): resolves the keys (saved to `.env`), creates the
`${DATA_ROOT}/rustfs_docker/{data,logs}` bind dirs and chowns them to **uid 10001**, `docker compose up -d`,
polls `/health` until the S3 API answers `200`, then verifies the keys with a `mc ls` (ListBuckets). It
ends with a **connection summary** (S3 endpoint, access/secret keys, console URL, an `aws s3` example, the
cross-host test command); the keys are shown once and saved to `.env`. A no-flag re-run **reuses** the
stored keys.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file and SET BOTH KEYS (compose declares them :?set in .env — refuses an empty key)
cp .env.example .env
sed -i "s/^RUSTFS_ACCESS_KEY=.*/RUSTFS_ACCESS_KEY=ChangeMe_AccessKey/" .env
sed -i "s/^RUSTFS_SECRET_KEY=.*/RUSTFS_SECRET_KEY=ChangeMe_StrongSecretKey/" .env

# 2. create the host bind-mount dirs and own them to the container's uid (10001)
sudo mkdir -p /data/rustfs_docker/data /data/rustfs_docker/logs
sudo chown -R 10001:10001 /data/rustfs_docker
sudo chmod -R 755 /data/rustfs_docker

# 3. bring it up (reads .env for image tag, ports, keys)
docker compose up -d

# 4. WAIT for the S3 API to come up before verifying (the image has a 20s start_period —
#    an immediate check races the container; poll /health until it answers 200, like setup.sh does)
until [ "$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:9000/health)" = 200 ]; do sleep 2; done
docker compose ps                                                       # STATUS -> healthy
curl -fsS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:9000/health   # -> 200
docker run --rm -i --network host \
  -e MC_HOST_rfs="http://ChangeMe_AccessKey:ChangeMe_StrongSecretKey@127.0.0.1:9000" \
  minio/mc:latest --no-color ls rfs                                    # -> ListBuckets OK (no error)
```

> **Browser console:** once up, open `http://<host>:9001` and log in with the access/secret keys above.

## Test

The shared contract test (via the `mc` S3 client) lists buckets (auth), creates a **throwaway** bucket,
PUTs 2 bilingual-UTF-8 objects, GETs them back byte-identical, asserts the list count, stats, server-side
copies, then removes everything and proves **zero residue**.

### A. Scripted test

```bash
# from utility/10_RustFS/  (reads creds + port from this variant's .env)
bash ../test.sh 03_docker_single

# cross-host (test client ≠ this host) — paste the keys setup.sh printed:
RUSTFS_HOST=<host> RUSTFS_API_PORT=9000 RUSTFS_ACCESS_KEY=<ak> RUSTFS_SECRET_KEY=<sk> bash ../test.sh
```

### B. Manual test (raw write → read → clean-up)

```bash
# point mc at the container (use your actual keys); one PUT → GET (UTF-8) → drop, zero residue
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
bash setup.sh status        # docker compose ps + S3 /health + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — objects PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/rustfs_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted objects are PRESERVED either way
docker compose down               # objects kept
docker compose down -v            # also fine — bind mounts survive -v

# full wipe — ALSO delete the host data dir (irreversible)
docker compose down -v
sudo rm -rf /data/rustfs_docker
```

## Notes

- **Browser UI:** the built-in RustFS console at `http://<host>:9001` (log in with the access/secret keys).
- S3-compatible — connect with any AWS SDK / `aws s3` CLI / `mc` client. Endpoint `http://<host>:9000`.
- The container runs as **uid 10001**; `setup.sh` chowns the bind dirs. If it crash-loops with
  `Permission denied`, re-run `purge` then `up` (or re-`chown -R 10001:10001 /data/rustfs_docker`).
- Single node = no erasure coding / no HA. For HA use `04_docker_cluster` (distributed RustFS).

## See also

- `../README.md` — how to use `test.sh` across all install variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the 4-node distributed (HA) variant.
