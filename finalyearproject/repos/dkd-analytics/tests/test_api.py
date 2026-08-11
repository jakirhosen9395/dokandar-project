"""Read surface: advisory envelope, mart validation, readiness degradation."""

from typing import Any

from fastapi.testclient import TestClient

from analytics import api
from analytics.config import Config


def cfg() -> Config:
    return Config(port=0, ch_url="x", ch_user="u", ch_password="", kafka_brokers="x",
                  demand_window_ms=1, build_info_path="/nonexistent")


def client(rows: dict[str, list[dict[str, Any]]], healthy: bool = True) -> TestClient:
    def run_query(sql: str, _params: dict[str, Any]) -> list[dict[str, Any]]:
        for key, result in rows.items():
            if key in sql:
                return result
        return []
    return TestClient(api.build_app(cfg(), run_query, lambda: healthy))


def test_shortage_view_flags_undersupplied_gpid() -> None:
    c = client({
        "sum(quantity) AS supply": [{"gpid": "GP-x", "supply": 110}],
        "ProductRecalled": [],
        "sum(quantity) AS demand": [{"gpid": "GP-x", "demand": 100}],
    })
    body = c.get("/v1/analytics/shortages").json()
    assert body["success"] is True
    item = body["data"][0]
    assert item["class"] == "WATCH"
    assert item["advisory"] is True
    assert body["meta"]["asOf"] > 0


def test_recalled_gpid_is_excluded_from_shortages() -> None:
    c = client({
        "sum(quantity) AS supply": [{"gpid": "GP-x", "supply": 10}],
        "ProductRecalled": [{"gpid": "GP-x", "n": 1}],
        "sum(quantity) AS demand": [{"gpid": "GP-x", "demand": 100}],
    })
    assert c.get("/v1/analytics/shortages").json()["data"] == []


def test_price_hint_404_when_no_trades() -> None:
    assert client({}).get("/v1/analytics/price-hints").status_code == 404


def test_unknown_mart_is_problem_json() -> None:
    r = client({}).get("/v1/analytics/marts/secret_table/asOf")
    assert r.status_code == 404
    assert r.headers["content-type"].startswith("application/problem+json")


def test_known_mart_reports_rows_and_watermark() -> None:
    c = client({"fact_orders": [{"rows": 7, "as_of": 123}]})
    body = c.get("/v1/analytics/marts/fact_orders/asOf").json()
    assert body["data"] == {"mart": "fact_orders", "rows": 7, "asOf": 123}


def test_ready_degrades() -> None:
    assert client({}, healthy=False).get("/ready").status_code == 503
    assert client({}, healthy=True).get("/ready").status_code == 200
