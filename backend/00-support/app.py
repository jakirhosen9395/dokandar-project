"""
sms-consumer — a DEV/STAGE stand-in for the SMS provider/channel.

In production a real SMS gateway consumes the auth service's OTP delivery queue
(`notifications.otp.send`) and texts the code to the user. For dev/stage there is
no carrier, so this service plays that exact role: it CONSUMES the same queue but
instead of sending an SMS it just stores the codes and lets anyone browse them —
open IP:port, search by phone or email, read the OTP. No SMS is sent.

  auth → RabbitMQ "notifications.otp.send" {phone, code, purpose, ttl}
       → sms-consumer (this) → web UI / JSON API

The queue message carries only `phone`; to allow searching by EMAIL we resolve
email → phone against the auth `users` table (read-only, optional — set
DATABASE_URL). If DATABASE_URL is unset, only phone search works.

⚠ SECURITY: this exposes live OTP codes with NO authentication — by design, for
dev/stage. It refuses to start unless APP_ENV is 'dev' or 'stage'. Keep its port
off public networks. NEVER run it in production.
"""
from __future__ import annotations

import asyncio
import base64
import hashlib
import hmac
import json
import os
import time
import uuid
from collections import deque
from contextlib import asynccontextmanager
from html import escape
from typing import Optional

import aio_pika
import httpx
from fastapi import FastAPI, HTTPException, Query, Request, Response
from fastapi.responses import HTMLResponse, JSONResponse

import logging


def _configure_uvicorn_logging():
    try:
        from uvicorn.logging import AccessFormatter, DefaultFormatter
        _datefmt = "%d-%m-%Y %H:%M:%S"
        _uv_default = DefaultFormatter("%(asctime)s    %(levelprefix)s %(message)s", datefmt=_datefmt)
        _uv_access = AccessFormatter(
            '%(asctime)s    %(client_addr)s - "%(request_line)s" %(status_code)s',
            datefmt=_datefmt,
        )
        for _name, _fmt in (("uvicorn", _uv_default),
                            ("uvicorn.error", _uv_default),
                            ("uvicorn.access", _uv_access)):
            _lg = logging.getLogger(_name)
            if not _lg.handlers:
                _lg.addHandler(logging.StreamHandler())
                _lg.propagate = False
            for _h in _lg.handlers:
                _h.setFormatter(_fmt)
    except Exception:
        pass

APP_ENV = os.environ.get("APP_ENV", "dev")
SERVICE_NAME = os.environ.get("SERVICE_NAME", "00-support")
try:
    CODE_VERSION = open(os.path.join(os.path.dirname(os.path.abspath(__file__)), "CODE_VERSION")).read().strip()
except Exception:
    CODE_VERSION = "00-support"
RABBITMQ_URL = os.environ.get("RABBITMQ_URL", "")
OTP_QUEUE = os.environ.get("OTP_QUEUE", "notifications.otp.send")
DATABASE_URL = os.environ.get("DATABASE_URL", "")  # optional: enables email search
BUF_MAX = int(os.environ.get("BUFFER_SIZE", "500"))
# payment webhook simulator (stub-mode confirmation): point at the payment svc +
# use the SAME stub secret it verifies against.
PAYMENT_BASE_URL = os.environ.get("PAYMENT_BASE_URL", "http://172.17.0.1:10009")
PAYMENT_STUB_SECRET = os.environ.get("PAYMENT_STUB_WEBHOOK_SECRET", "dokandar_payment_stub_secret_dev")
PAYMENT_PROVIDERS = ("bkash", "nagad", "rocket", "sslcommerz", "stripe")

if APP_ENV not in ("dev", "stage"):
    raise SystemExit(
        f"support refuses to start with APP_ENV={APP_ENV!r}. It exposes OTP "
        "codes with no auth and is strictly a dev/stage tool."
    )
if not RABBITMQ_URL:
    raise SystemExit("support needs RABBITMQ_URL (same value the auth service uses).")

# normalise a SQLAlchemy-style DSN to a plain asyncpg one
_PG_DSN = DATABASE_URL.replace("postgresql+asyncpg://", "postgresql://") if DATABASE_URL else ""

_buf: deque[dict] = deque(maxlen=BUF_MAX)  # captured OTP tasks (oldest first)
_state = {"connected": False, "consumed": 0, "last_error": "", "db": False}
_pool = None  # asyncpg pool, if DATABASE_URL set


async def _consume_loop() -> None:
    while True:
        try:
            conn = await aio_pika.connect_robust(RABBITMQ_URL)
            ch = await conn.channel()
            await ch.set_qos(prefetch_count=50)
            # PASSIVE declare — auth owns the queue + its args; we only assert it
            # exists (respecifying different args would raise PRECONDITION_FAILED).
            queue = await ch.declare_queue(OTP_QUEUE, passive=True)
            _state["connected"] = True
            _state["last_error"] = ""
            async with queue.iterator() as it:
                async for message in it:
                    async with message.process():  # ack — we "delivered" it
                        try:
                            data = json.loads(message.body.decode())
                            if not isinstance(data, dict):
                                data = {"raw": data}
                        except Exception:
                            data = {"raw": message.body.decode(errors="replace")}
                        data["received_at"] = time.time()
                        _buf.append(data)
                        _state["consumed"] += 1
        except asyncio.CancelledError:
            raise
        except Exception as e:  # noqa: BLE001
            _state["connected"] = False
            _state["last_error"] = f"{type(e).__name__}: {str(e)[:180]}"
            await asyncio.sleep(3)


@asynccontextmanager
async def lifespan(app: FastAPI):
    global _pool
    _configure_uvicorn_logging()
    if _PG_DSN:
        try:
            import asyncpg
            _pool = await asyncpg.create_pool(_PG_DSN, min_size=1, max_size=3, timeout=5)
            _state["db"] = True
        except Exception as e:  # noqa: BLE001
            _state["last_error"] = f"db pool: {type(e).__name__}: {str(e)[:120]}"
            _pool = None
    task = asyncio.create_task(_consume_loop(), name="otp-consumer")
    try:
        yield
    finally:
        task.cancel()
        try:
            await task
        except Exception:
            pass
        if _pool is not None:
            await _pool.close()


app = FastAPI(title="DOKANDAR support (dev/stage hub)", lifespan=lifespan)


@app.exception_handler(Exception)
async def _unhandled(request: Request, exc: Exception):
    """Backstop: any unexpected error returns a clean message and keeps the
    service running — a dependency hiccup never takes the hub down."""
    return JSONResponse(
        status_code=500,
        content={
            "error": "support hub hit an unexpected error (the service is still running)",
            "detail": f"{type(exc).__name__}: {str(exc)[:200]}",
            "path": str(request.url.path),
        },
    )


def _view(e: dict) -> dict:
    now = time.time()
    received = e.get("received_at", now)
    age = now - received
    ttl = e.get("ttl") or 0
    return {
        "phone": e.get("phone"),
        "code": e.get("code"),
        "purpose": e.get("purpose"),
        "ttl": ttl,
        "age_seconds": round(age, 1),
        "expired": bool(ttl and age > ttl),
        "raw": e.get("raw"),
    }


async def _emails_to_phones(value: str):
    """Resolve email → user phone(s) via the auth users table.
    Returns a list (possibly empty = no match), or None if the DB lookup itself
    failed (so the caller can say 'DB down' instead of 'no match')."""
    if not _pool:
        return []
    try:
        rows = await _pool.fetch(
            "SELECT phone FROM users WHERE lower(email) = lower($1)", value.strip()
        )
        return [r["phone"] for r in rows]
    except Exception as e:  # noqa: BLE001 — never let a DB blip crash the request
        _state["last_error"] = f"email lookup: {type(e).__name__}: {str(e)[:120]}"
        return None


async def _resolve_phones(q: str) -> tuple[list[str], Optional[str]]:
    """Return (phones to match, note). '@' → email lookup; else treat as phone.
    Degrades gracefully: a DB outage yields an explanatory note, not a crash."""
    q = q.strip()
    if "@" in q:
        if not _pool:
            if not DATABASE_URL:
                return [], "email search needs DATABASE_URL (auth DB) — not configured; search by phone instead"
            return [], "email search unavailable — the auth database could not be reached at startup (phone search still works)"
        phones = await _emails_to_phones(q)
        if phones is None:
            return [], "email search unavailable — the auth database is unreachable right now (phone search still works)"
        if not phones:
            return [], f"no user found with email {q}"
        return phones, None
    return [q], None


def _matches(phones: list[str]) -> list[dict]:
    items = [_view(e) for e in _buf if e.get("phone") in phones]
    return items[::-1]  # newest first


# ---------------------------------------------------------------------------
# JSON API
# ---------------------------------------------------------------------------
@app.get("/search")
async def search(q: str = Query(..., description="phone or email to look up")):
    phones, note = await _resolve_phones(q)
    items = _matches(phones) if phones else []
    return {"query": q, "resolved_phones": phones, "note": note,
            "count": len(items), "items": items}


@app.get("/otp/latest")
async def otp_latest(
    phone: Optional[str] = None,
    email: Optional[str] = None,
    purpose: Optional[str] = None,
):
    if not phone and not email:
        raise HTTPException(400, "provide phone or email")
    phones, note = await _resolve_phones(email or phone)  # type: ignore[arg-type]
    items = [e for e in _matches(phones) if purpose is None or e["purpose"] == purpose]
    if not items:
        raise HTTPException(404, note or f"no OTP captured for {email or phone}")
    return items[0]


@app.get("/health")
async def health():
    body = {
        "status": "ok" if _state["connected"] else "degraded",
        "service": SERVICE_NAME,
        "code_version": CODE_VERSION,
        "env": APP_ENV,
        "queue": OTP_QUEUE,
        "rabbitmq_connected": _state["connected"],
        "email_search": _state["db"],
        "messages_consumed": _state["consumed"],
        "buffered": len(_buf),
        "last_error": _state["last_error"],
    }
    # pretty-printed JSON
    return Response(
        content=json.dumps(body, indent=2) + "\n",
        media_type="application/json",
        status_code=200 if _state["connected"] else 503,
    )


# ---------------------------------------------------------------------------
# Standard ops-contract endpoints — /ready /data /metrics (join /health above).
# Every DOKANDAR service exposes this set; support previously shipped only /health.
# ---------------------------------------------------------------------------
import time as _time
from pathlib import Path as _Path

_BOOT_TS = _time.time()
_TENANT = os.environ.get("TENANT", "cloud")
_DATA_DIR = _Path(os.path.dirname(os.path.abspath(__file__))) / "data"


def _identity() -> dict:
    return {
        "service_name": SERVICE_NAME,
        "code_version": CODE_VERSION,
        "env_version": os.environ.get("ENV_VERSION", "v1.0.0"),
        "tenant": _TENANT,
        "env": APP_ENV,
        "uptime_seconds": int(_time.time() - _BOOT_TS),
    }


@app.get("/ready")
async def ready():
    # Load-balancer gate: 200 as soon as the HTTP server is serving. support has no
    # hard dependency to answer traffic (RabbitMQ consumption is best-effort), so it
    # is ready when the process is up — deliberately does NOT flip on RabbitMQ state.
    return Response(
        content=json.dumps({**_identity(), "ready": True}, indent=2) + "\n",
        media_type="application/json",
        status_code=200,
    )


@app.get("/data")
async def data():
    # Serve the bind-mounted read-only tenant snapshot (data/<tenant>/result.json),
    # identity block prepended — mirrors the fleet /data contract (01-auth).
    snap = _DATA_DIR / _TENANT / "result.json"
    if not snap.is_file():
        return Response(
            content=json.dumps(
                {**_identity(), "error": {"code": "no_snapshot",
                 "message": f"no data/{_TENANT}/result.json (run data/{_TENANT}/collect.sh)"}},
                indent=2) + "\n",
            media_type="application/json", status_code=404,
        )
    try:
        payload = json.loads(snap.read_text())
    except Exception as e:  # noqa: BLE001 — surface a clean 500 rather than crash the route
        return Response(
            content=json.dumps(
                {**_identity(), "error": {"code": "snapshot_parse_failed", "message": str(e)[:120]}},
                indent=2) + "\n",
            media_type="application/json", status_code=500,
        )
    body = {**_identity(), **(payload if isinstance(payload, dict) else {"snapshot": payload})}
    return Response(content=json.dumps(body, indent=2) + "\n",
                    media_type="application/json", status_code=200)


@app.get("/metrics")
async def metrics():
    # Minimal Prometheus text exposition (the fleet /metrics contract).
    lines = [
        "# HELP support_up 1 if the support service process is up.",
        "# TYPE support_up gauge",
        "support_up 1",
        "# HELP support_messages_consumed_total OTP messages consumed from the queue.",
        "# TYPE support_messages_consumed_total counter",
        f"support_messages_consumed_total {int(_state.get('consumed', 0))}",
        "# HELP support_buffered OTP entries currently buffered.",
        "# TYPE support_buffered gauge",
        f"support_buffered {len(_buf)}",
        "# HELP support_rabbitmq_connected 1 if the RabbitMQ consumer is connected.",
        "# TYPE support_rabbitmq_connected gauge",
        f"support_rabbitmq_connected {1 if _state.get('connected') else 0}",
        "",
    ]
    return Response(content="\n".join(lines),
                    media_type="text/plain; version=0.0.4", status_code=200)


# ---------------------------------------------------------------------------
# Shared shell + navbar — every page is served under this one host:port.
# ---------------------------------------------------------------------------
# NOTE: plain (non-f) string — literal CSS braces must NOT be inside an f-string.
_CSS = """
*{box-sizing:border-box}
body{font-family:-apple-system,system-ui,'Segoe UI',Roboto,Arial,sans-serif;background:#eef1f5;color:#1f2933;margin:0;line-height:1.5}
.wrap{max-width:640px;margin:0 auto;padding:0 16px 56px}
header{background:#0f2742;color:#fff;padding:14px 0}
header .wrap{display:flex;align-items:center;gap:10px}
.brand{font-weight:800;font-size:18px}
.tag{font-size:11px;background:#f0b429;color:#1f2933;padding:3px 9px;border-radius:20px;font-weight:800;margin-left:auto}
nav.tabs{display:flex;gap:10px;margin:20px 0 4px}
nav.tabs a{flex:1;text-align:center;padding:14px 10px;border-radius:12px;text-decoration:none;background:#fff;color:#0f2742;font-weight:700;border:1px solid #d9e0e8;font-size:15px}
nav.tabs a.active{background:#1a73e8;color:#fff;border-color:#1a73e8;box-shadow:0 2px 8px rgba(26,115,232,.35)}
.card{background:#fff;border:1px solid #e3e8ee;border-radius:16px;padding:24px;margin:18px 0;box-shadow:0 1px 4px rgba(15,39,66,.06)}
h1{font-size:22px;margin:0 0 6px}
.sub{color:#5f6b7a;margin:0 0 18px;font-size:15px}
label{display:block;font-weight:700;margin:16px 0 6px;font-size:14px}
input,select,textarea{width:100%;padding:13px;font-size:16px;border:1.5px solid #cdd5df;border-radius:11px;background:#fff;color:#1f2933}
input:focus,select:focus,textarea:focus{outline:none;border-color:#1a73e8}
button{background:#1a73e8;color:#fff;border:0;padding:14px 20px;font-size:16px;font-weight:700;border-radius:11px;cursor:pointer;width:100%;margin-top:18px}
button.green{background:#1e8e3e}
.code{font:800 34px/1.2 ui-monospace,Menlo,monospace;letter-spacing:7px;text-align:center;background:#eaf2ff;border:2px dashed #1a73e8;color:#0f2742;padding:18px;border-radius:14px;width:100%}
.badge{display:inline-block;padding:6px 14px;border-radius:20px;font-size:14px;font-weight:800}
.badge.ok{background:#e6f4ea;color:#137333}
.badge.bad{background:#fce8e6;color:#c5221f}
.alert{padding:14px 16px;border-radius:11px;margin:14px 0;font-size:14.5px}
.alert.warn{background:#fef7e0;border:1px solid #f0c000;color:#7a5b00}
.muted{color:#90a0b0;font-size:13px}
details{margin-top:16px}summary{cursor:pointer;color:#1a73e8;font-weight:700}
pre{background:#0f2742;color:#cfe0f2;padding:14px;border-radius:11px;overflow:auto;font-size:12.5px}
a.link{color:#1a73e8;font-weight:600}
.center{text-align:center}
"""

_NAV_ITEMS = (
    ("/", "🔑 Get login code", "otp"),
    ("/webhook", "💳 Confirm payment", "webhook"),
)


def _nav(active: str) -> str:
    links = "".join(
        "<a class='" + ("active" if key == active else "") + "' href='" + href + "'>"
        + escape(label) + "</a>"
        for href, label, key in _NAV_ITEMS
    )
    return "<nav class=tabs>" + links + "</nav>"


def _shell(title: str, inner: str, active: str = "", head_extra: str = "") -> str:
    return (
        "<!doctype html><html lang=en><head><meta charset=utf-8>"
        "<meta name=viewport content='width=device-width,initial-scale=1'>"
        + head_extra
        + "<title>" + escape(title) + " · Dokandar Test Helper</title>"
        + "<style>" + _CSS + "</style></head><body>"
        + "<header><div class=wrap><span class=brand>🧪 Dokandar Test Helper</span>"
        + "<span class=tag>DEV / STAGE</span></div></header>"
        + "<div class=wrap>" + _nav(active) + inner + "</div></body></html>"
    )


# ---------------------------------------------------------------------------
# Web UI — open IP:port, type a phone or email, see the OTP
# ---------------------------------------------------------------------------
@app.get("/", response_class=HTMLResponse)
async def home(request: Request, q: str = ""):
    note = None
    if q:
        phones, note = await _resolve_phones(q)
        rows_data = _matches(phones) if phones else []
    else:
        rows_data = []  # privacy: nothing shown until a phone/email is searched

    qval = escape(q)
    # while a search is active, refresh on its own so a freshly-sent code appears
    refresh = "<meta http-equiv=refresh content=5>" if q else ""

    rmq_banner = "" if _state["connected"] else (
        "<div class='alert warn'>⚠ The code service is temporarily unavailable, so new codes "
        "may not appear right now. It reconnects automatically — try again shortly.</div>"
    )
    note_html = f"<div class='alert warn'>{escape(note)}</div>" if note else ""

    if q and rows_data:
        latest = rows_data[0]
        code = escape(str(latest["code"] or ""))
        purpose = escape(str(latest["purpose"] or "code"))
        age = int(latest["age_seconds"])
        badge = ("<span class='badge bad'>Expired — please request a new code</span>"
                 if latest["expired"] else
                 "<span class='badge ok'>✓ Valid — use this code now</span>")
        result = (
            "<div class=card>"
            f"<p class=sub>Code for <b>{escape(str(latest['phone'] or q))}</b> · {purpose} · sent {age}s ago</p>"
            f"<input class=code readonly value='{code}' onclick='this.select()' aria-label='your code'>"
            f"<p class=center style='margin-top:14px'>{badge}</p>"
            "<p class='muted center'>Tap the code to select it, then copy.</p>"
            "</div>"
        )
    elif q:
        result = (
            "<div class=card>"
            f"<p class=sub>No code found yet for <b>{qval}</b>.</p>"
            "<p>Make sure you tapped <b>“Send code”</b> in the app you're testing — the code "
            "appears here within a few seconds (this page updates on its own).</p>"
            "</div>"
        )
    else:
        result = ""

    inner = (
        "<div class=card>"
        "<h1>Get your login / signup code</h1>"
        "<p class=sub>Testing the app and waiting for an SMS verification code? Enter the phone "
        "number (or email) you used and the code will show up here.</p>"
        f"{rmq_banner}{note_html}"
        "<form method=get action='/'>"
        "<label>Phone number or email</label>"
        f"<input name=q value='{qval}' placeholder='e.g. 01712345678' autofocus>"
        "<button>Show my code</button>"
        "</form>"
        "</div>"
        f"{result}"
    )
    return _shell("Get login code", inner, active="otp", head_extra=refresh)


# ===========================================================================
# Webhook simulator — "payment confirmation" (the stub-mode payment provider
# callback) and a generic signed-webhook poster. This is the dev/stage
# stand-in for a real provider's async callback: it builds the JSON body,
# signs it with HMAC-SHA256(body, secret) in the X-Signature header (exactly
# what the payment service verifies in stub mode), and POSTs it.
# ===========================================================================
def _hmac_b64(secret: str, raw: bytes) -> str:
    return base64.b64encode(hmac.new(secret.encode(), raw, hashlib.sha256).digest()).decode()


def _safe_json(r: httpx.Response):
    try:
        return r.json()
    except Exception:
        return (r.text or "")[:500]


async def _post_signed(url: str, body: dict, secret: Optional[str], sig_header: str = "X-Signature") -> dict:
    """POST a (optionally signed) webhook. Never raises on a network failure —
    returns {error, target_down:true} so an unreachable target shows a clear
    message instead of taking the request (or service) down."""
    raw = json.dumps(body).encode()
    headers = {"Content-Type": "application/json"}
    if secret:
        headers[sig_header] = _hmac_b64(secret, raw)
    try:
        async with httpx.AsyncClient(timeout=10) as c:
            r = await c.post(url, content=raw, headers=headers)
        return {"http_status": r.status_code, "response": _safe_json(r)}
    except httpx.HTTPError as e:
        return {"http_status": 0, "target_down": True,
                "error": f"target unreachable: {type(e).__name__}: {str(e)[:160]}"}


async def _pay_confirm(provider, order_id, intent_id, amount_minor, status) -> dict:
    provider = (provider or "bkash").lower()
    if provider not in PAYMENT_PROVIDERS:
        raise HTTPException(400, f"provider must be one of {PAYMENT_PROVIDERS}")
    if not order_id:
        raise HTTPException(400, "order_id required")
    txn = "stub_txn_" + uuid.uuid4().hex[:16]
    body = {
        "order_id": str(order_id),
        "intent_id": intent_id or f"stub_{provider}_{str(order_id)[:8]}",
        "provider_txn_id": txn,
        "status": status or "completed",
        "amount_minor": int(amount_minor or 0),
        "event_id": "evt_" + txn,
    }
    url = f"{PAYMENT_BASE_URL}/api/v1/payment/webhooks/{provider}"
    res = await _post_signed(url, body, PAYMENT_STUB_SECRET)
    if res.get("target_down"):
        res["error"] = f"payment service unreachable at {url} — is it up? ({res['error']})"
    return {"sent_to": url, "signed_body": body, **res}


@app.post("/pay/confirm")
async def pay_confirm_api(request: Request):
    """JSON API: {provider?, order_id, intent_id?, amount_minor?, status?}."""
    p = await request.json()
    return await _pay_confirm(p.get("provider"), p.get("order_id"), p.get("intent_id"),
                              p.get("amount_minor"), p.get("status"))


@app.post("/webhook/send")
async def webhook_send_api(request: Request):
    """JSON API: {url, body, secret?, sig_header?} — generic signed POST."""
    p = await request.json()
    if "url" not in p:
        raise HTTPException(400, "url required")
    res = await _post_signed(p["url"], p.get("body", {}), p.get("secret"), p.get("sig_header", "X-Signature"))
    return {"sent_to": p["url"], **res}


_PROVIDER_LABELS = {
    "bkash": "bKash", "nagad": "Nagad", "rocket": "Rocket",
    "sslcommerz": "SSLCommerz (card / bank)", "stripe": "Card (Stripe)",
}


def _result_html(title: str, res: dict) -> str:
    status = res.get("http_status", 0)
    err = res.get("error")
    down = bool(res.get("target_down")) or status == 0
    ok = (not err) and 200 <= status < 300
    if down:
        head, cls, msg = "Couldn't reach the service", "bad", \
            "The service didn't respond. Make sure it's running, then try again."
    elif ok:
        head, cls, msg = "Done ✓", "ok", "Success — the request was accepted."
    else:
        head, cls, msg = "Not accepted", "bad", \
            f"The service responded but didn't accept it (status {status}). See the details below."
    raw = escape(json.dumps(res, indent=2))
    inner = (
        "<div class=card>"
        f"<p><span class='badge {cls}'>{escape(head)}</span></p>"
        f"<p class=sub>{escape(msg)}</p>"
        "<details><summary>Technical details</summary>"
        f"<pre>{raw}</pre></details>"
        "<p style='margin-top:18px'><a class=link href='/webhook'>← Back</a></p>"
        "</div>"
    )
    return _shell(title, inner, active="webhook")


@app.get("/webhook", response_class=HTMLResponse)
async def webhook_ui():
    opts = "".join(
        "<option value='" + p + "'>" + _PROVIDER_LABELS.get(p, p) + "</option>"
        for p in PAYMENT_PROVIDERS
    )
    inner = (
        "<div class=card>"
        "<h1>Confirm a test payment</h1>"
        "<p class=sub>Pretend the customer just paid. Pick the method, paste the Order ID from "
        "the checkout screen you're testing, then confirm — we'll tell the system it's paid.</p>"
        "<form method=post action='/webhook/pay'>"
        "<label>Payment method</label>"
        "<select name=provider>" + opts + "</select>"
        "<label>Order ID <span class=muted>(from the checkout screen you're testing)</span></label>"
        "<input name=order_id required placeholder='paste the order ID'>"
        "<label>Amount in ৳ <span class=muted>(optional)</span></label>"
        "<input name=amount_taka type=number min=0 step=any placeholder='e.g. 500'>"
        "<label>Result</label>"
        "<select name=status><option value=completed>Paid ✓</option>"
        "<option value=failed>Failed ✗</option></select>"
        "<button class=green>Confirm payment</button>"
        "</form>"
        "</div>"
        "<details><summary>Advanced — send a custom webhook (for developers)</summary>"
        "<div class=card>"
        "<p class=sub>POST any JSON to any endpoint, optionally HMAC-signed. Use the docker-bridge "
        "address, e.g. <code>http://172.17.0.1:10009/...</code>.</p>"
        "<form method=post action='/webhook/raw'>"
        "<label>Target URL</label>"
        "<input name=url required placeholder='http://172.17.0.1:100NN/...'>"
        "<label>JSON body</label>"
        "<textarea name=body_json rows=5>{}</textarea>"
        "<label>HMAC secret (optional)</label>"
        "<input name=secret>"
        "<label>Signature header</label>"
        "<input name=sig_header value='X-Signature'>"
        "<button>Send webhook</button>"
        "</form>"
        "</div></details>"
    )
    return _shell("Confirm payment", inner, active="webhook")


@app.post("/webhook/pay", response_class=HTMLResponse)
async def webhook_pay_ui(request: Request):
    f = await request.form()
    try:
        minor = int(round(float(f.get("amount_taka") or 0) * 100))  # ৳ → minor units
    except (TypeError, ValueError):
        minor = 0
    res = await _pay_confirm(f.get("provider"), f.get("order_id"), None,
                             minor, f.get("status") or "completed")
    return _result_html("Payment confirmation", res)


@app.post("/webhook/raw", response_class=HTMLResponse)
async def webhook_raw_ui(request: Request):
    f = await request.form()
    try:
        body = json.loads(f.get("body_json") or "{}")
    except Exception:
        raise HTTPException(400, "body must be valid JSON")
    res = await _post_signed(f.get("url"), body, (f.get("secret") or None), f.get("sig_header") or "X-Signature")
    return _result_html("Generic webhook", {"sent_to": f.get("url"), **res})
