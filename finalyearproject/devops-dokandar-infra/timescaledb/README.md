# TimescaleDB — time-series PostgreSQL utility

PostgreSQL 17 with the TimescaleDB extension (hypertables, time_bucket) — the pattern for
metrics/telemetry storage. Runs on :5433 because plain PostgreSQL owns :5432 on this server.

## Quick start (infra-2)
```bash
cd docker-single-node-setup && bash setup_env.sh && bash setup.sh up
cd .. && bash test.sh    # proves hypertables + time_bucket, not just SQL
```

## Reaching it from OUTSIDE
```bash
PGPASSWORD='<pw>' psql -h <server-ip> -p 5433 -U dki -d dki_metrics -c "SELECT extversion FROM pg_extension WHERE extname='timescaledb';"
```
Port tcp/5433 is open.
