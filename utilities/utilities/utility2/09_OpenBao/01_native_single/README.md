# OpenBao 2.x — native single-node (no Docker)

The fleet's secrets store for DOKANDAR (RS256 signing key + `INTERNAL_SERVICE_TOKEN` custody). This
variant installs OpenBao from the official `.deb`, managed by **systemd** (**no Docker**), file storage
under **`/data/openbao`** (preserved on uninstall), with the built-in web UI on `:8200/ui`. Tested on
**Ubuntu 26.04 (resolute)**.

- **What runs:** the `openbao` `.deb` (the `bao` binary + the `openbao` system user), a single server
  with **file storage**, plaintext listener (TLS disabled — dev), and the built-in UI.
- **Data:** `${DATA_ROOT}/openbao` (default `/data/openbao`). Install is **non-destructive** (an existing
  `/data/openbao` is reused, never wiped); uninstall **keeps the data** (the seal + secrets); only `purge`
  deletes them.
- **Browser UI:** the built-in OpenBao UI at `http://<host>:8200/ui` (log in with the root token).
- **Seal model:** OpenBao boots **sealed + uninitialised**. `setup.sh` initialises it (1 unseal key,
  threshold 1 — a **dev** convenience; production uses 5-of-3 Shamir + auto-unseal + TLS), unseals it,
  enables a **KV v2** engine at `secret/`, and saves the **root token + unseal key** to `.env`.

Install / test / uninstall each come in **two interchangeable ways**: **A. Scripted** — the idempotent
`setup.sh` (initialises + unseals, enables KV v2, prints a connection summary); and **B. Manual** — raw
copy-paste Ubuntu commands that run the exact same steps by hand, no script. Both produce the same server.

## Configure

```bash
cp .env.example .env        # optional — edit listener / port; the token + key are written by install
```

`.env` is gitignored (it holds the real root token + unseal key); only `.env.example` is committed. Key
vars: `DATA_ROOT`, `BAO_VERSION` (default `2.5.4`), `BAO_LISTEN` (default `0.0.0.0`), `BAO_API_PORT`
(default `8200`). **`BAO_ROOT_TOKEN` and `BAO_UNSEAL_KEY` are written by `install` — do not pre-fill
them.** Set `BAO_LISTEN=127.0.0.1` to keep the listener loopback-only.

## Install

### A. Scripted install (recommended)

```bash
cp .env.example .env
sudo bash setup.sh install
```

Prints **numbered step output** (1/5 … 5/5 with ✓ ticks): config + data dir → install the OpenBao `.deb`
+ create the `openbao` user → write the HCL config (file storage, listener, UI) + systemd unit + start
(server boots **sealed**) → **initialise + unseal** (saves the root token + unseal key to `.env`, chmod
600) → enable **KV v2** at `secret/` + verify. Ends with a **connection summary** — API endpoint, the
`:8200/ui` URL, root token, unseal key, and the data directory. The root token is **shown once**.
Re-running is **idempotent**: it reuses the saved token/key and re-unseals.

### B. Manual install (raw Ubuntu commands)

Run these by hand instead of the script — they are exactly what `setup.sh install` does. OpenBao isn't in
the Ubuntu base archive, so the binary comes from the official GitHub `.deb` release.

```bash
# 1. data dir (file storage lives here) — non-destructive
sudo mkdir -p /data/openbao

# 2. install the official OpenBao .deb (2.x line) — creates the `bao` binary + the `openbao` system user
BV=2.5.4
sudo apt-get update -y && sudo apt-get install -y wget curl ca-certificates python3
wget -qO /tmp/bao.deb "https://github.com/openbao/openbao/releases/download/v${BV}/openbao_${BV}_linux_amd64.deb"
sudo dpkg -i /tmp/bao.deb && rm -f /tmp/bao.deb
id openbao >/dev/null 2>&1 || sudo useradd --system --no-create-home --shell /usr/sbin/nologin openbao
bao --version

# 3. server config — file storage, plaintext listener (dev), built-in UI on
sudo mkdir -p /etc/openbao
sudo tee /etc/openbao/openbao.hcl >/dev/null <<'HCL'
storage "file" { path = "/data/openbao" }
listener "tcp" {
  address     = "0.0.0.0:8200"
  tls_disable = true
}
api_addr      = "http://127.0.0.1:8200"
ui            = true
disable_mlock = true
HCL
sudo chown -R openbao:openbao /data/openbao /etc/openbao

# 4. systemd unit + start (the server boots SEALED + uninitialised — that is expected)
sudo tee /etc/systemd/system/openbao.service >/dev/null <<'UNIT'
[Unit]
Description=OpenBao
After=network-online.target
Wants=network-online.target
[Service]
User=openbao
Group=openbao
ExecStart=/usr/bin/bao server -config=/etc/openbao/openbao.hcl
Restart=on-failure
[Install]
WantedBy=multi-user.target
UNIT
sudo systemctl daemon-reload
sudo systemctl enable --now openbao
until curl -s --max-time 3 'http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200' >/dev/null; do sleep 2; done

# 5. initialise (1 key / threshold 1 — DEV) + capture the root token + unseal key
INIT=$(curl -s -X PUT http://127.0.0.1:8200/v1/sys/init -d '{"secret_shares":1,"secret_threshold":1}')
ROOT_TOKEN=$(printf '%s' "$INIT" | python3 -c "import sys,json;print(json.load(sys.stdin)['root_token'])")
UNSEAL_KEY=$(printf '%s' "$INIT" | python3 -c "import sys,json;print(json.load(sys.stdin)['keys_base64'][0])")
echo "ROOT TOKEN : $ROOT_TOKEN"     # save these OUT OF BAND (and into .env if you want setup.sh to reuse them)
echo "UNSEAL KEY : $UNSEAL_KEY"

# 6. unseal, then enable a KV v2 engine at secret/
curl -s -X PUT http://127.0.0.1:8200/v1/sys/unseal -d "{\"key\":\"${UNSEAL_KEY}\"}" >/dev/null
curl -s -X POST -H "X-Vault-Token: ${ROOT_TOKEN}" http://127.0.0.1:8200/v1/sys/mounts/secret \
  -d '{"type":"kv","options":{"version":"2"}}' >/dev/null

# 7. verify (service active; initialized=true, sealed=false; secret/ mounted)
systemctl is-active openbao                                                            # -> active
curl -s 'http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200'           # initialized:true sealed:false
curl -s -H "X-Vault-Token: ${ROOT_TOKEN}" http://127.0.0.1:8200/v1/sys/mounts | grep -q '"secret/"' && echo 'KV v2 at secret/ OK'
```

> **Persist the credentials.** If you want a later `setup.sh install` to reuse this token/key (instead of
> re-initialising), write them into `.env`: `BAO_ROOT_TOKEN=<root-token>` and `BAO_UNSEAL_KEY=<unseal-key>`
> (`chmod 600 .env`). Treat both as secrets.

## Test

The contract test confirms the server is **initialised + unsealed**, writes a throwaway KV v2 secret
(bilingual UTF-8 `চাল-rice`), reads it back, then **destroys it and proves zero residue** (read → 404).

### A. Scripted test (the shared contract test)

```bash
# from utility/09_OpenBao/  (auto-reads the root token + port from 01_native_single/.env)
bash test.sh 01_native_single

# cross-host (pass the token explicitly):
BAO_HOST=<host> BAO_TOKEN=<root-token> bash test.sh
```

Exits `0` and prints `RESULT: PASS` when every check passes and nothing is left behind.

### B. Manual test (raw write → read → clean-up)

```bash
# use the root token from install (or `. ./.env` to load $BAO_ROOT_TOKEN)
T=<root-token>; P=dokandar_smoke

# write a KV v2 secret (bilingual UTF-8) → read it back
curl -s -H "X-Vault-Token: $T" -X POST http://127.0.0.1:8200/v1/secret/data/$P \
  -d '{"data":{"name":"চাল-rice","qty":"100"}}' >/dev/null
curl -s -H "X-Vault-Token: $T" http://127.0.0.1:8200/v1/secret/data/$P     # -> "name":"চাল-rice","qty":"100"

# destroy it + PROVE zero residue (read -> 404)
curl -s -H "X-Vault-Token: $T" -X DELETE http://127.0.0.1:8200/v1/secret/metadata/$P >/dev/null
curl -s -o /dev/null -w '%{http_code}\n' -H "X-Vault-Token: $T" http://127.0.0.1:8200/v1/secret/data/$P   # -> 404
```

## Status / logs

```bash
sudo bash setup.sh status        # service + init/sealed state + data-dir size
# manual equivalents:
systemctl is-active openbao
curl -s 'http://127.0.0.1:8200/v1/sys/health?uninitcode=200&sealedcode=200'
sudo journalctl -u openbao -n 80 -f
```

## Uninstall

### A. Scripted uninstall

Removes the package + config but **keeps the data** (seal + secrets) at `/data/openbao`:

```bash
sudo bash setup.sh uninstall     # stop + disable + purge the package/config; DATA PRESERVED
sudo bash setup.sh purge         # also deletes /data/openbao (secrets + seal gone — unrecoverable)
```

### B. Manual uninstall (raw Ubuntu commands)

```bash
# stop + disable + remove the unit
sudo systemctl stop openbao
sudo systemctl disable openbao
sudo rm -f /etc/systemd/system/openbao.service
sudo systemctl daemon-reload

# purge the package + config (data on /data is NOT touched)
sudo apt-get purge -y openbao
sudo apt-get autoremove --purge -y
sudo rm -rf /etc/openbao

# full wipe — ALSO delete the data (secrets + seal, irreversible)
sudo rm -rf /data/openbao
```

## See also

- `../README.md` — the OpenBao utility overview + how to use `test.sh` across all variants.
- `../03_docker_single/` — the Docker Compose single-node variant.
- `../04_docker_cluster/` — the 3-node integrated-Raft HA variant.
- `../../../dependencies/08_Edge_secrets_frontend/01_OpenBao_2.x/` — the original bare-metal install scripts
  + the canonical manual-install / verify reference these commands mirror.
