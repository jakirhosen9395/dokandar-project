#!/usr/bin/env bash
# Runs ONCE on the primary's first init (against the image's temp init server, before the real server
# starts). Creates the physical-replication role + one slot per replica and allows replication
# connections in pg_hba. Physical slots are persistent, so they survive the temp->real restart; the
# healthcheck only goes green after this completes, which is why the replicas' depends_on:healthy
# guarantees the slots exist before they pg_basebackup.
set -euo pipefail
: "${REPL_USER:=replicator}"
: "${REPL_PASSWORD:=replicator-secret}"

psql -v ON_ERROR_STOP=1 --username "$POSTGRES_USER" --dbname "${POSTGRES_DB:-postgres}" <<SQL
DO \$\$ BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='${REPL_USER}') THEN
    CREATE ROLE ${REPL_USER} WITH REPLICATION LOGIN PASSWORD '${REPL_PASSWORD}';
  END IF;
END \$\$;
SELECT pg_create_physical_replication_slot('replica1_slot')
  WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='replica1_slot');
SELECT pg_create_physical_replication_slot('replica2_slot')
  WHERE NOT EXISTS (SELECT 1 FROM pg_replication_slots WHERE slot_name='replica2_slot');
SQL

# Allow replication connections from the compose network (pg_basebackup + the ongoing walreceiver).
# (Belt-and-suspenders: the official image may already emit a `host replication ...` line.)
echo "host replication ${REPL_USER} all scram-sha-256" >> "$PGDATA/pg_hba.conf"
echo "[primary-init] replication role '${REPL_USER}' + 2 physical slots created; pg_hba rule added."
