"""Bootstrap: CREATE DATABASE dokandar_auth_<env> if missing, then run alembic upgrade head.

Runs SYNCHRONOUSLY before the app accepts requests. Uses asyncpg for the admin
connection (to the bootstrap `postgres` DB) so we don't need a sync driver.
"""
from __future__ import annotations
import asyncio
import json
import re
import subprocess
import sys
from datetime import datetime
from urllib.parse import urlparse, urlunparse
import asyncpg
from app.config import settings


def _log(level: str, message: str) -> None:
    """Canonical fleet log shape for bootstrap output (runs before logging is
    configured), so it matches the running service's structured logs."""
    print(json.dumps({
        "asctime": datetime.now().strftime("%Y-%m-%d %H:%M:%S,%f")[:-3],
        "name": "auth.ensure_db", "levelname": level, "message": message,
    }, indent=2), flush=True)


def _admin_target_dbname() -> tuple[str, str]:
    """Return (admin_dsn_no_driver, target_db_name)."""
    # POSTGRES_DSN uses SQLAlchemy dialect like postgresql+asyncpg://…
    target = urlparse(settings.postgres_dsn.replace("postgresql+asyncpg://", "postgresql://"))
    admin = urlparse(settings.postgres_admin_dsn.replace("postgresql+asyncpg://", "postgresql://"))
    target_db = target.path.lstrip("/")
    # Force admin DSN to point at the `postgres` DB
    admin_no_db = admin._replace(path="/postgres")
    return urlunparse(admin_no_db), target_db


async def _create_db_if_missing() -> None:
    admin_dsn, target_db = _admin_target_dbname()
    if not re.match(r"^[A-Za-z_][A-Za-z0-9_]*$", target_db):
        raise SystemExit(f"refusing to create DB with unsafe name: {target_db!r}")
    conn = await asyncpg.connect(admin_dsn)
    try:
        exists = await conn.fetchval(
            "SELECT 1 FROM pg_database WHERE datname = $1", target_db
        )
        if exists:
            _log("INFO", f"database {target_db!r} already exists")
            return
        _log("INFO", f"creating database {target_db!r}")
        # CREATE DATABASE cannot run inside a TX
        await conn.execute(f'CREATE DATABASE "{target_db}"')
    finally:
        await conn.close()


def _run_alembic_upgrade() -> None:
    _log("INFO", "running alembic upgrade head")
    r = subprocess.run(
        ["alembic", "upgrade", "head"],
        check=False, capture_output=False,
    )
    if r.returncode != 0:
        sys.exit(f"alembic upgrade head failed (rc={r.returncode})")


def _ensure_kyc_bucket() -> None:
    """Create the RustFS KYC bucket if missing."""
    try:
        from app.storage import s3 as s3_mod
        s3_mod.ensure_bucket()
    except Exception as e:
        _log("WARNING", f"KYC bucket bootstrap skipped: {e}")


def main() -> None:
    asyncio.run(_create_db_if_missing())
    _run_alembic_upgrade()
    _ensure_kyc_bucket()


if __name__ == "__main__":
    main()
