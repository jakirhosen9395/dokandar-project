"""RiskProfile + velocity counters in Redis (DM ctx #10: Redis = streaming feature store).
Counters are per-DID sorted sets trimmed to the sliding window; profiles carry a TTL."""

from __future__ import annotations

import json
from typing import Any

import redis

from fraud import ids


class RiskStore:
    def __init__(self, url: str, window_ms: int, profile_ttl_s: int) -> None:
        self._r: redis.Redis = redis.Redis.from_url(url, decode_responses=True)
        self._window_ms = window_ms
        self._ttl = profile_ttl_s

    def ping(self) -> bool:
        try:
            return bool(self._r.ping())
        except redis.RedisError:
            return False

    def bump(self, kind: str, did: str, event_id: str, at_ms: int) -> int:
        """Record one event occurrence and return the in-window count. Idempotent per
        event_id (sorted-set member), so consumer redeliveries never double-count."""
        key = f"fraud:vel:{kind}:{did}"
        pipe = self._r.pipeline()
        pipe.zadd(key, {event_id: at_ms})
        pipe.zremrangebyscore(key, 0, at_ms - self._window_ms)
        pipe.zcard(key)
        pipe.expire(key, max(self._ttl, self._window_ms // 1000))
        out = pipe.execute()
        return int(out[2])

    def count(self, kind: str, did: str, now_ms: int) -> int:
        key = f"fraud:vel:{kind}:{did}"
        pipe = self._r.pipeline()
        pipe.zremrangebyscore(key, 0, now_ms - self._window_ms)
        pipe.zcard(key)
        return int(pipe.execute()[1])

    def put_profile(self, did: str, profile: dict[str, Any]) -> None:
        self._r.set(f"fraud:profile:{did}", json.dumps(profile), ex=self._ttl)

    def get_profile(self, did: str) -> dict[str, Any] | None:
        raw = self._r.get(f"fraud:profile:{did}")
        if raw is None:
            return None
        loaded = json.loads(str(raw))
        return loaded if isinstance(loaded, dict) else None

    def profile_for(self, did: str, order_count: int, trade_count: int,
                    assessment_fields: dict[str, Any]) -> dict[str, Any]:
        profile = {
            "subjectDid": did,
            "velocityCounters": [
                {"key": "orders", "count": order_count, "windowMs": self._window_ms},
                {"key": "trades", "count": trade_count, "windowMs": self._window_ms},
            ],
            "computedAt": ids.now_ms(),
            **assessment_fields,
        }
        self.put_profile(did, profile)
        return profile
