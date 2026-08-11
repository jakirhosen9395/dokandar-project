# ScyllaDB — wide-column (Cassandra-compatible) learning utility

From the reference library — DOKANDAR doesn't consume it yet; it's here to learn the
Cassandra data model (keyspaces, partition keys, CQL) on a properly-capped single node
(developer mode, 1 core, 350M — seastar's own budget calculation rejects more inside a container).

## Quick start (infra-2)
```bash
cd docker-single-node-setup && bash setup_env.sh && bash setup.sh up   # ~1 min to healthy
cd .. && bash test.sh
```

## Reaching it from OUTSIDE
CQL is a binary protocol — use cqlsh from any machine with docker:
```bash
docker run --rm -it scylladb/scylla:2025.1 cqlsh <server-ip> 9042 -e "SELECT release_version FROM system.local"
```
Port tcp/9042 is open. No auth (learning utility).
