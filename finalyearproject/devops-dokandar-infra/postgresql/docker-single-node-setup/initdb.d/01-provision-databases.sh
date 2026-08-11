#!/bin/bash
# First-boot provisioning (runs ONCE, when the data directory is empty).
# Creates every database in DKD_DATABASES with a same-named owner role.
# Passwords are set afterwards by setup.sh (which also handles ADDING databases
# to an already-running server — this file only covers a brand-new one).
set -e
IFS=',' read -ra DBS <<< "${DKD_DATABASES:-}"
for db in "${DBS[@]}"; do
  db="$(echo "$db" | tr -d '[:space:]')"; [ -z "$db" ] && continue
  echo "provisioning database + role: $db"
  psql -v ON_ERROR_STOP=1 -U "$POSTGRES_USER" -d postgres <<SQL
    CREATE ROLE "$db" LOGIN;
    CREATE DATABASE "$db" OWNER "$db";
SQL
done
