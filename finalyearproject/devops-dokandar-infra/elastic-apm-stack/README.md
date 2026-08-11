# Elastic APM stack — observability utility (built FIRST)

Elasticsearch 9.2 + Kibana + APM Server, ported from
[jakirhosen9395/elastic-apm-stack](https://github.com/jakirhosen9395/elastic-apm-stack) and
sized for a shared 8GB host (explicit heaps + mem limits on all three containers).
Security is ON — the stack generates real passwords.

## Quick start (on infra-1)
```bash
cd docker-single-node-setup
bash setup_env.sh    # generates ELASTIC/KIBANA passwords + encryption key + APM token
bash setup.sh up     # ES → kibana_system bootstrap → Kibana → APM server
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
- **Kibana (browser):** http://<server-ip>:5601 — log in as `elastic` with the password
  from `.env` (printed by `setup.sh up`).
- **Elasticsearch:** `curl -u elastic:<pw> http://<server-ip>:9200/_cluster/health`
- **APM intake:** point any Elastic APM agent at `http://<server-ip>:8200` with the
  `APM_SECRET_TOKEN` from `.env`.

Ports tcp/5601, 9200, 8200 are open in the security group.

## What test.sh proves
Anonymous ES rejected (401) → authed health green/yellow → UTF-8 index round-trip →
Kibana status → APM intake rejects a wrong token (401) and accepts the real one (202) →
throwaway index deleted, zero residue.
