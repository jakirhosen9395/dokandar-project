# DOKANDAR — Jump Server Config & Secret Management

All Kubernetes ConfigMaps AND Secrets are managed FROM THIS FOLDER on the jump
server. The manifests in ../manifest-files contain **no ConfigMap or Secret
objects** — every Deployment expects `<service>-config` and `<service>-secret`
to already exist in its namespace (referenced via `envFrom`).

```
jump-server/
├── config/NN-<svc>/<name>.env            # non-sensitive env (committed, real values)
├── secrets/NN-<svc>/<name>.env.example   # secret KEY templates (committed, empty values)
├── secrets/NN-<svc>/<name>.env           # real secret values (GITIGNORED, jump server only)
├── apply-config.sh             # config/*.env  → ConfigMaps
└── apply-secrets.sh            # secrets/*.env → Secrets
```

## Flow

1. Config: edit `config/NN-<svc>/<name>.env` as needed (non-sensitive: APP_ENV, TENANT,
   LOG_LEVEL, service URLs …), then `./apply-config.sh`.
2. Secrets: `cp secrets/NN-<svc>/<name>.env.example secrets/NN-<svc>/<name>.env`, fill the values
   (source: `all_components_creds.txt` / each service's `env/init-env.sh`
   output — same credential flow as the Docker deployment), then
   `./apply-secrets.sh`.
3. Apply the manifests (see ../manifest-files/README.md).

Order matters: **config + secrets first, then manifests** — pods will not
become Ready without them.

Rotate/change by editing the env file and re-running the apply script
(stakater Reloader restarts the affected pods automatically).
