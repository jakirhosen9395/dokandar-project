"""Auth-specific Prometheus metrics.

These augment the framework-level RED metrics added automatically by
`prometheus_fastapi_instrumentator` (`http_requests_total`,
`http_request_duration_seconds`, etc.). Anything domain-specific to
identity/OTP/JWT belongs here so Grafana can build the operational
dashboards listed in `docs/services/auth.md` §16:

  - auth_otp_requests_total{purpose}              — OTP sent (signup/login)
  - auth_otp_verify_total{purpose,result}         — verify outcomes (ok/invalid/expired/exhausted)
  - auth_tokens_issued_total{type,role}           — access + refresh issued, broken down by role
  - auth_active_refresh_tokens                    — gauge (set from a DB count on /metrics scrape)
  - auth_refresh_reuse_detected_total             — every family-revoke event (security signal)
  - auth_signup_total{role}                       — successful provisionings, per role
  - auth_outbox_pending                           — gauge (rows in outbox not yet sent → relay lag)
  - auth_outbox_relayed_total                     — counter of successful relays

Every counter has stable label values (closed set) so Prometheus cardinality
stays bounded. Gauges are computed on-scrape via the `Instrumentator`'s
`add` hook rather than maintained eagerly (cheap when /metrics is rare,
correct without push/pull races).
"""
from __future__ import annotations

import logging
from prometheus_client import Counter, Gauge
from sqlalchemy import select, func

log = logging.getLogger("auth.metrics")


# --- counters: cheap, no DB ---------------------------------------------------

otp_requests = Counter(
    "auth_otp_requests_total",
    "OTPs issued.",
    labelnames=("purpose",),  # signup | login
)
otp_verify = Counter(
    "auth_otp_verify_total",
    "OTP verification outcomes.",
    labelnames=("purpose", "result"),  # purpose=signup|login; result=ok|invalid|expired|exhausted
)
tokens_issued = Counter(
    "auth_tokens_issued_total",
    "Access + refresh tokens issued.",
    labelnames=("type", "role"),  # type=access|refresh; role=admin|shopkeeper|shop_staff|platform_staff|customer
)
refresh_reuse_detected = Counter(
    "auth_refresh_reuse_detected_total",
    "Number of refresh-token replay attempts (every one revokes the family).",
)
signups = Counter(
    "auth_signup_total",
    "Successful user provisionings (self-signup + role-matrix creates).",
    labelnames=("role",),
)
outbox_relayed = Counter(
    "auth_outbox_relayed_total",
    "Outbox rows successfully shipped to Kafka by the relay loop.",
)

# --- KYC counters -----------------------------------------------------------

kyc_submitted = Counter(
    "auth_kyc_submitted_total",
    "KYC submissions accepted into the review queue.",
)
kyc_decision = Counter(
    "auth_kyc_decision_total",
    "KYC decisions taken (verified | rejected).",
    labelnames=("decision",),  # verified | rejected
)

# --- gauges: refreshed on /metrics scrape from the DB -----------------------

active_refresh_tokens = Gauge(
    "auth_active_refresh_tokens",
    "Refresh tokens currently valid (not revoked, not expired).",
)
outbox_pending = Gauge(
    "auth_outbox_pending",
    "Outbox rows awaiting relay (lag indicator).",
)


async def refresh_gauges_from_db() -> None:
    """Recompute the on-scrape gauges. Called from a /metrics middleware
    hook installed in app/main.py just before Prometheus renders the
    exposition. Cheap (~one PK count each); safe to call once per scrape.
    """
    # Imported here to avoid circular import at module load.
    from datetime import datetime, timezone
    from app.db.models import RefreshToken, Outbox
    from app.db.session import SessionLocal

    try:
        async with SessionLocal() as db:
            now = datetime.now(timezone.utc)
            rt = (await db.execute(
                select(func.count(RefreshToken.id)).where(
                    RefreshToken.revoked_at.is_(None),
                    RefreshToken.expires_at > now,
                )
            )).scalar_one()
            active_refresh_tokens.set(int(rt))

            ob = (await db.execute(
                select(func.count(Outbox.id)).where(Outbox.sent_at.is_(None))
            )).scalar_one()
            outbox_pending.set(int(ob))
    except Exception as e:
        # never let metrics computation break the /metrics scrape
        log.warning("gauge refresh failed: %s", e)
