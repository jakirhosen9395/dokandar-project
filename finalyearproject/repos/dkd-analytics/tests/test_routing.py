"""Routing determinism + the 45-topic registry surface (INV-ANL-4: canonical IDs only)."""

from analytics import routing


def test_registry_surface_is_45_topics() -> None:
    assert len(routing.CONSUMED_TOPICS) == 45
    assert len(set(routing.CONSUMED_TOPICS)) == 45


def test_order_placed_routes_with_item_gpid() -> None:
    [(table, row)] = routing.route(
        "b2c.order.OrderPlaced.v1", "e1",
        {"ord": "ORD-1", "buyerDid": "did:dokandar:b", "sellerDid": "did:dokandar:s",
         "totalAmountPoisha": 3000, "occurredAt": 42,
         "items": [{"gpid": "GP-rice-1", "quantity": 2, "unitPricePoisha": 1500}]}, 99)
    assert table == "fact_orders"
    assert row["gpid"] == "GP-rice-1"
    assert row["quantity"] == 2
    assert row["amount_poisha"] == 3000
    assert row["occurred_at"] == 42
    assert row["ingest_ts"] == 99


def test_trade_created_extracts_unit_price() -> None:
    [(table, row)] = routing.route(
        "b2b.tradeorder.TradeOrderCreated.v1", "e2",
        {"trd": "TRD-1", "totalAmountPoisha": 20000,
         "items": [{"gpid": "GP-rice-1", "agreedUnitPricePoisha": 2000}]}, 5)
    assert table == "fact_trade_orders"
    assert row["unit_price_poisha"] == 2000


def test_custody_initialized_routes_quantity() -> None:
    [(table, row)] = routing.route(
        "custody.passport.CustodyInitialized.v1", "e3",
        {"ppid": "PP-1", "gpid": "GP-x", "holder": "did:dokandar:s", "quantity": 50,
         "unit": "kg", "occurredAt": 7}, 9)
    assert table == "fact_custody_events"
    assert row["quantity"] == 50


def test_escrow_event_routes_to_settlements() -> None:
    [(table, row)] = routing.route(
        "finance.escrow.EscrowReleased.v1", "e4",
        {"esc": "ESC-1", "referenceId": "TRD-1", "referenceType": "TRADE"}, 9)
    assert table == "fact_settlements"
    assert row["ref"] == "ESC-1"
    assert row["reference_type"] == "TRADE"


def test_fraud_signal_routes_score() -> None:
    [(table, row)] = routing.route(
        "fraud.enforcement.FraudSignalRaised.v1", "e5",
        {"subjectDid": "did:dokandar:x", "reason": "HOARDING", "riskScore": 0.72}, 9)
    assert table == "fact_fraud_signals"
    assert row["risk_score"] == 0.72


def test_unknown_topic_routes_nowhere() -> None:
    assert routing.route("identity.party.PartyRegistered.v1", "e", {}, 1) == []
    assert routing.route("", "e", {}, 1) == []  # reviewer MEDIUM: empty topic never crashes


def test_multi_item_order_emits_one_row_per_line() -> None:
    rows = routing.route(
        "b2c.order.OrderPlaced.v1", "e9",
        {"ord": "ORD-9", "occurredAt": 1, "items": [
            {"gpid": "GP-a", "quantity": 2}, {"gpid": "GP-b", "quantity": 5}]}, 2)
    assert len(rows) == 2
    assert rows[0][1]["event_id"] == "e9"
    assert rows[1][1]["event_id"] == "e9#1"  # distinct dedup key per line
    assert rows[1][1]["gpid"] == "GP-b"


def test_route_is_deterministic() -> None:
    args = ("b2c.order.OrderPlaced.v1", "e1", {"ord": "ORD-1", "occurredAt": 1}, 2)
    assert routing.route(*args) == routing.route(*args)  # FR-ANL-009
