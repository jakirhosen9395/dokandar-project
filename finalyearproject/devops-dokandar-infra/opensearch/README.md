# OpenSearch 2.17 — utility

DOKANDAR's full-text search engine (product discovery). This teaching node runs with the
security plugin OFF (plain HTTP, no password) — the same as the platform's local config —
so you can learn the search API easily. **Enable security for real deployments.**

## Quick start
```bash
cd docker-single-node-setup
bash setup_env.sh && bash setup.sh up   # also raises vm.max_map_count (search engines need it)
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
Port tcp/9201 is open on the dedicated server <server-ip>. From your laptop:
```bash
curl http://<server-ip>:9201/_cluster/health?pretty
curl http://<server-ip>:9201/               # version + tagline
```
