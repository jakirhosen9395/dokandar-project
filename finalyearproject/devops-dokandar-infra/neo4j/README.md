# Neo4j 5.26 Community — utility

DOKANDAR's graph store (the provenance graph — a CQRS projection of the custody ledger).
Ships with the Neo4j Browser, a great way to LEARN Cypher visually.

## Quick start
```bash
cd docker-single-node-setup
bash setup_env.sh && bash setup.sh up
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
- **Browser:** http://<server-ip>:7474  — log in with user `neo4j` + the password from `.env`.
  In "Connect URL" use `bolt://<server-ip>:7687`.
Ports tcp/7474 (browser) and tcp/7687 (Bolt) are open.
