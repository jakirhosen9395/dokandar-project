# OpenBao 2.x — utility dependency

OpenBao (the MPL OSS fork of HashiCorp Vault) is DOKANDAR's secrets store — services authenticate via
AppRole and read their credentials/keys from it (`00-support` and others). It boots **sealed +
uninitialised** (no username/password); the **root token + unseal keys** come from `operator init`. This
folder holds the install variants plus a **shared test script** for all of them.

## Layout

```text
09_OpenBao/
├── README.md            ← this file
├── test.sh              ← shared contract/smoke test (curl + HTTP API) — works against ALL variants
├── 01_native_single/    ← native (no Docker), .deb + systemd, file storage in /data/openbao     [TESTED]
├── 03_docker_single/    ← Docker Compose, file storage bind-mounted (survives down -v)           [TESTED]
└── 04_docker_cluster/   ← Docker Compose HA: 3-node integrated Raft (one unseal key, 3 voters)   [TESTED]
```

(`02_native_cluster` is intentionally skipped — the Dockerised 3-node Raft cluster covers HA.)

> **Init / unseal / auth.** OpenBao starts sealed and uninitialised. Each variant's `setup.sh`
> **initialises** it (1 unseal key / threshold 1 — a DEV convenience; production uses 5-of-3 Shamir + a
> proper auto-unseal), **unseals** it, enables a **KV v2** engine at `secret/`, and writes the generated
> **root token + unseal key** to that variant's `.env` (chmod 600). The cluster uses one unseal key for
> all three nodes. TLS is disabled (dev) — restrict at the firewall; the tests run over an SG-fenced VPC.

## The shared test script — `test.sh`

Uses **`curl`** against the HTTP API (token in the `X-Vault-Token` header). It confirms the server is
**initialised + unsealed**, writes a throwaway **KV v2** secret (bilingual UTF-8), reads it back, then
**destroys** it and **proves zero residue** (404).

### How to run it

```bash
bash test.sh 01_native_single     # native (reads BAO_ROOT_TOKEN + port from its .env)
# or against ANY OpenBao (e.g. cross-host) — pass host + token via env:
BAO_HOST=<host> BAO_TOKEN=<root-token> bash test.sh
```

### Reading the result

`RESULT: PASS — secret written/read/destroyed, zero residue.` and exit `0` means the server is unsealed
and the KV path works. Any failure prints the failing checks.

## See also

- `../README.md` — the utility-dependency overview.
- `../../dependencies/08_Edge_secrets_frontend/01_OpenBao_2.x/` — the original install scripts + the
  `cluster_mode/run_book.md` native integrated-Raft HA reference (3 voters, Raft replication).
