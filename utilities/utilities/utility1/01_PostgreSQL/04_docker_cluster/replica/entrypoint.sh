#!/usr/bin/env bash
# DOKANDAR PG cluster — replica bootstrap entrypoint (runs as root, before the image entrypoint).
#
# First start (empty data dir): wait for the primary, clone it with pg_basebackup (-R writes
# standby.signal + a PASSWORD-LESS primary_conninfo + primary_slot_name), then EMBED a full
# primary_conninfo (with the password) into postgresql.auto.conf — because libpq reads the password
# from ~/.pgpass (HOME), NOT $PGDATA/.pgpass, so the -R conninfo alone can't authenticate the stream.
# Restart (data present, persisted on the bind mount): skip the clone and just resume streaming.
# Either way, hand off to the official entrypoint, which starts this node as a hot standby.
set -euo pipefail
: "${PGDATA:=/var/lib/postgresql/pgdata}"
: "${PRIMARY_HOST:=pg-primary}"
: "${REPL_USER:=replicator}"
: "${REPL_PASSWORD:=replicator-secret}"
: "${REPL_SLOT:?REPL_SLOT must be set}"

if [ ! -s "$PGDATA/PG_VERSION" ]; then
  echo "[replica:${REPL_SLOT}] empty data dir -> cloning from ${PRIMARY_HOST}"
  # the bind-mounted /var/lib/postgresql is root-owned (create_host_path) — hand the whole tree to
  # postgres so the gosu basebackup can create PGDATA and write auto.conf under it.
  chown -R postgres:postgres /var/lib/postgresql
  until pg_isready -h "$PRIMARY_HOST" -p 5432 -q; do echo "[replica:${REPL_SLOT}] waiting for ${PRIMARY_HOST}..."; sleep 2; done
  gosu postgres env PGPASSWORD="$REPL_PASSWORD" \
    pg_basebackup -h "$PRIMARY_HOST" -p 5432 -U "$REPL_USER" -D "$PGDATA" -Fp -Xs -R -S "$REPL_SLOT" -P -v
  # Embed the password into primary_conninfo (last setting wins over the -R one). printf keeps the
  # single-quoted conninfo value intact; primary_slot_name written by -R is left untouched.
  printf "primary_conninfo = 'host=%s port=5432 user=%s password=%s application_name=%s'\n" \
    "$PRIMARY_HOST" "$REPL_USER" "$REPL_PASSWORD" "$REPL_SLOT" \
    | gosu postgres tee -a "$PGDATA/postgresql.auto.conf" >/dev/null
  echo "[replica:${REPL_SLOT}] clone complete; streaming password embedded."
else
  echo "[replica:${REPL_SLOT}] existing data dir -> resuming streaming (no basebackup)."
fi

# NOTE: compose `entrypoint:` clears the image CMD, so "$@" is empty here — hand off to the official
# entrypoint with an explicit `postgres` so the server actually starts (as a hot standby).
exec docker-entrypoint.sh postgres
