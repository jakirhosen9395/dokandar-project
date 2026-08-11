"""Create the Postgres database if absent, then apply migrations/*.sql."""
from __future__ import annotations

import logging
import re
import sys
from pathlib import Path

import psycopg

from app.config import settings


log = logging.getLogger("reco.ensure_db")
logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s")


_DB_NAME_RE = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*$")


def _create_db_if_missing() -> None:
    db = settings.postgres_db
    if not _DB_NAME_RE.match(db):
        raise SystemExit(f"refusing CREATE DATABASE — {db!r} fails identifier validation")
    with psycopg.connect(settings.postgres_admin_dsn, autocommit=True) as conn:
        with conn.cursor() as cur:
            cur.execute("SELECT 1 FROM pg_database WHERE datname = %s", (db,))
            if cur.fetchone():
                log.info("database %s already exists", db)
                return
            cur.execute(f'CREATE DATABASE "{db}"')
            log.warning("created database %s", db)


def _apply_migrations() -> None:
    migrations = Path(__file__).resolve().parents[2] / "migrations"
    files = sorted(p for p in migrations.glob("*.sql") if p.is_file())
    if not files:
        log.warning("no migrations under %s", migrations)
        return
    with psycopg.connect(settings.postgres_dsn, autocommit=False) as conn:
        with conn.cursor() as cur:
            for f in files:
                log.info("applying migration %s", f.name)
                cur.execute(f.read_text())
        conn.commit()


def main() -> int:
    try:
        _create_db_if_missing()
        _apply_migrations()
    except Exception:
        log.exception("ensure_db failed")
        return 1
    log.info("ensure_db ok — db=%s", settings.postgres_db)
    return 0


if __name__ == "__main__":
    sys.exit(main())
