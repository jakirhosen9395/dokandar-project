# OpenBao 2.x — Docker Compose single-node

One `openbao/openbao` container run via Docker Compose, configured from the committed `./openbao.hcl`,
with file storage on a **host bind mount** so the seal + secrets **survive `docker compose down -v`**,
`restart: always`. The built-in web UI is on `:8200/ui`. `setup.sh` initialises + unseals the server and
enables a **KV v2** engine, then saves the root token + unseal key to `.env`.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the `setup.sh`
wrapper (brings the container up, initialises + unseals, enables KV v2, prints a connection summary); and
**B. Manual** — raw `docker compose` + `curl` commands (create the env + data dir, bring it up, then init
+ unseal + enable KV by hand). Both produce the same container.

## Why the data survives `docker compose down -v`

`docker compose down -v` removes containers **and named/anonymous volumes**. It does **not** touch a
**bind mount** (a host directory). This compose file stores OpenBao's file-storage data on a bind mount
(`${DATA_ROOT}/openbao_docker` → the container's `/openbao/data`) and declares **no named volume at all**,
so:

| Command | Container | Data (`${DATA_ROOT}/openbao_docker`) |
| --- | --- | --- |
| `docker compose down` | removed | **kept** (seal + secrets) |
| `docker compose down -v` | removed | **kept** (nothing for `-v` to remove) |
| `docker compose up -d` | recreated | **reused** — the next `up`/`setup.sh up` re-unseals with the saved key |
| `bash setup.sh purge` | removed | **deleted** (the only way) |

So `down -v` then `up` returns to the same secrets (re-unseal with the saved key). The *only* way to
delete the data is `setup.sh purge` (or `rm -rf ${DATA_ROOT}/openbao_docker` by hand).

> The container **bypasses the image entrypoint** (`entrypoint: ["bao"]`) and runs as **root**
> (`user: "0:0"`, `cap_add: [IPC_LOCK]`) so the root-owned bind-mounted data dir is writable — the stock
> entrypoint drops to a non-root user that can't write it.

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

The contract test talks to the API over `curl` (or, if `curl` is absent, a `curlimages/curl` container) —
no extra client package is needed.

## Configure

```bash
cp .env.example .env        # required — `docker compose` reads it; edit host port / image tag if needed
```

`.env` is gitignored; only `.env.example` is committed. Vars: `BAO_VERSION` (image tag, default `2.5.4`),
`BAO_API_PORT` (host port → container 8200, default `8200`), `DATA_ROOT`. **`BAO_ROOT_TOKEN` and
`BAO_UNSEAL_KEY` are written by `setup.sh up` after `operator init` — do not pre-fill them.** If a native
OpenBao already holds `8200`, set a different `BAO_API_PORT` (e.g. `8201`). Unlike a database image,
OpenBao needs **no password in `.env` before `up`** — the server boots sealed and the root token + unseal
key are *generated* by the init step (scripted or manual), not preset.

## Install / up

### A. Scripted install (recommended)

```bash
cp .env.example .env
bash setup.sh up
```

`setup.sh up` prints **numbered step output** (1/4 … 4/4): create the bind-mount data dir +
`docker compose up -d` → **initialise** (idempotent — reuses `.env` token/key if already initialised) →
**unseal** → enable **KV v2** at `secret/`. The root token + unseal key are saved to `.env` (chmod 600)
and the root token is **shown once** in the **connection summary** (API endpoint, `:8200/ui` URL, token,
unseal key, host data dir). A no-flag re-run reuses the stored token/key.

### B. Manual install (raw docker compose)

```bash
# 1. create the env file (no password needed — OpenBao generates its own token + unseal key on init)
cp .env.example .env

# 2. create the host bind-mount data dir (compose can also auto-create it; explicit is clearer)
sudo mkdir -p /data/openbao_docker

# 3. bring the container up (reads .env for image tag + host port)
docker compose up -d
until curl -s --max-time 3 'http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200' >/dev/null; do sleep 2; done

# 4. initialise (1 key / threshold 1 — DEV) + capture the root token + unseal key
INIT=$(curl -s -X PUT http://127.0.0.1:8200/v1/sys/init -d '{"secret_shares":1,"secret_threshold":1}')
ROOT_TOKEN=$(printf '%s' "$INIT" | python3 -c "import sys,json;print(json.load(sys.stdin)['root_token'])")
UNSEAL_KEY=$(printf '%s' "$INIT" | python3 -c "import sys,json;print(json.load(sys.stdin)['keys_base64'][0])")
echo "ROOT TOKEN : $ROOT_TOKEN"     # save these OUT OF BAND (and into .env to let setup.sh reuse them)
echo "UNSEAL KEY : $UNSEAL_KEY"

# 5. unseal, then enable a KV v2 engine at secret/
curl -s -X PUT http://127.0.0.1:8200/v1/sys/unseal -d "{\"key\":\"${UNSEAL_KEY}\"}" >/dev/null
curl -s -X POST -H "X-Vault-Token: ${ROOT_TOKEN}" http://127.0.0.1:8200/v1/sys/mounts/secret \
  -d '{"type":"kv","options":{"version":"2"}}' >/dev/null

# 6. verify (container up; initialized=true, sealed=false; secret/ mounted)
docker compose ps
curl -s 'http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200'           # initialized:true sealed:false
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" http://127.0.0.1:8200/v1/sys/mounts | grep -q '"secret/"' && echo 'KV v2 at secret/ OK'
```

> **Persist the credentials.** Write `BAO_ROOT_TOKEN=<root-token>` and `BAO_UNSEAL_KEY=<unseal-key>` into
> `.env` (`chmod 600 .env`) so a later `setup.sh up` reuses them (re-unseal, no re-init). Treat both as
> secrets. If a non-default host port is used, adjust the `http://127.0.0.1:<port>` URLs above.

## Test

The shared contract test confirms the server is **initialised + unsealed**, writes a throwaway KV v2
secret (bilingual UTF-8 `চাল-rice`), reads it back, then destroys it and proves zero residue (read → 404).

### A. Scripted test

```bash
# from utility/09_OpenBao/
bash test.sh 03_docker_single

# cross-host (use the published port + the root token):
BAO_HOST=<host> BAO_API_PORT=8201 BAO_TOKEN=<root-token> bash test.sh
```

### B. Manual test (raw write → read → clean-up)

```bash
# use the root token from `up` (or `. ./.env` to load $BAO_ROOT_TOKEN)
T=<root-token>; P=dokandar_smoke

# write a KV v2 secret (bilingual UTF-8) → read it back
curl -s -H "X-Vault-Token: $T" -X POST http://127.0.0.1:8200/v1/secret/data/$P \
  -d '{"data":{"name":"চাল-rice","qty":"100"}}' >/dev/null
curl -s -H "X-Vault-Token: $T" http://127.0.0.1:8200/v1/secret/data/$P     # -> "name":"চাল-rice","qty":"100"

# destroy it + PROVE zero residue (read -> 404)
curl -s -H "X-Vault-Token: $T" -X DELETE http://127.0.0.1:8200/v1/secret/metadata/$P >/dev/null
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $T" http://127.0.0.1:8200/v1/secret/data/$P   # -> 404
```

## Data persistence

The file storage is a **host bind mount** (`${DATA_ROOT}/openbao_docker`), so `down`/`down -v` keep the
seal + secrets; the next `up` re-unseals with the saved key. Only `purge` deletes them (secrets gone).
Verified live: a secret written before `down -v` is readable after the next `up`.

## Status / logs

```bash
bash setup.sh status        # docker compose ps + init/sealed state + host data size
bash setup.sh logs          # follow container logs
# manual equivalents:
docker compose ps
docker compose logs --tail=80 -f
```

## Uninstall

### A. Scripted uninstall

```bash
bash setup.sh down          # stop + remove the container — data (seal + secrets) PRESERVED
bash setup.sh purge         # docker compose down -v + rm -rf /data/openbao_docker (full wipe)
```

### B. Manual uninstall (raw docker compose)

```bash
# stop + remove the container — bind-mounted data is PRESERVED either way
docker compose down               # data kept
docker compose down -v            # also fine — the bind mount survives -v

# full wipe — ALSO delete the host data dir (secrets + seal, irreversible)
docker compose down -v
sudo rm -rf /data/openbao_docker
```

## Notes

- **Browser UI:** the built-in OpenBao UI at `http://<host>:8200/ui` (or your published port) — log in
  with the root token.
- TLS disabled (dev); 1-key / threshold-1 init — restrict at the firewall and harden for production
  (TLS, 5-of-3 Shamir or auto-unseal).

## See also

- `../README.md` — using `test.sh` across all variants.
- `../01_native_single/` — the no-Docker, systemd-native variant.
- `../04_docker_cluster/` — the 3-node integrated-Raft HA variant.
