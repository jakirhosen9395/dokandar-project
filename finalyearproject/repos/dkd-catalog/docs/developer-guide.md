# Developer Guide — catalog-svc

- `make run` / `docker compose up` — local stack.
- Health: `/health` `/ready` `/live` `/version`; metrics on `:9090/metrics`.
- Config via environment (see `.env.example`) — 12-factor; secrets via the platform secret manager.
- Tests: unit + integration (testcontainers). CI runs them on every MR.
- Deploy: `helm upgrade --install catalog-svc deploy/helm/catalog-svc` or `kubectl apply -k deploy/k8s`.

Do not edit blueprint-owned wiring; re-scaffolding overwrites it. Add business logic in the
domain/application layers only.
