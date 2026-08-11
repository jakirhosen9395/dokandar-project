"""Topic → fact/dim routing (pure, unit-tested). The 45 registry topics with consumer=12,
verbatim from the frozen spine (ADR-016). Analytics produces NOTHING (registry has no
producer-12 entry — the SA §15.7 advisory topics are errata pending an additive ADR).
Rows carry canonical IDs only (INV-ANL-4) and the lineage event_id (FR-ANL-003)."""

from __future__ import annotations

from typing import Any

CATALOG = [
    "catalog.product.ProductCreated.v1", "catalog.product.ProductPublished.v1",
    "catalog.product.ProductDeprecated.v1", "catalog.product.ProductPriceRuleAdded.v1",
    "catalog.product.ProductMasterDataUpdated.v1",
]
CUSTODY = [
    "custody.passport.CustodyInitialized.v1", "custody.passport.CustodyTransferred.v1",
    "custody.passport.CustodySplit.v1", "custody.passport.CustodyMerged.v1",
    "custody.passport.ProductRecalled.v1", "custody.passport.CustodialSigned.v1",
]
B2C = [
    "b2c.order.OrderPlaced.v1", "b2c.order.PaymentConfirmed.v1",
    "b2c.order.OrderProcessingStarted.v1", "b2c.order.OrderShipped.v1",
    "b2c.order.OrderDelivered.v1", "b2c.order.OrderCancelled.v1", "b2c.order.OrderRefunded.v1",
]
B2B = [
    "b2b.tradeorder.TradeOrderCreated.v1", "b2b.tradeorder.MarginPosted.v1",
    "b2b.tradeorder.TradeActivated.v1", "b2b.tradeorder.SettlementInitiated.v1",
    "b2b.tradeorder.TradeSettled.v1", "b2b.tradeorder.TradeDisputed.v1",
    "b2b.tradeorder.TradeCancelled.v1",
]
FINANCE = [
    "finance.wallet.WalletCreated.v1", "finance.wallet.MFSAccountRegistered.v1",
    "finance.wallet.MFSAccountVerified.v1", "finance.wallet.WalletCredited.v1",
    "finance.wallet.WalletDebited.v1", "finance.wallet.WalletFrozen.v1",
    "finance.wallet.MFSWithdrawalInitiated.v1", "finance.wallet.MFSWithdrawalConfirmed.v1",
    "finance.wallet.MFSWithdrawalFailed.v1",
    "finance.escrow.EscrowCreated.v1", "finance.escrow.EscrowReleased.v1",
    "finance.escrow.SettlementHoldReleased.v1", "finance.escrow.EscrowReversed.v1",
]
LOGISTICS = [
    "logistics.shipment.ShipmentCreated.v1", "logistics.shipment.RiderAssigned.v1",
    "logistics.shipment.PickupRecorded.v1", "logistics.shipment.DeliveryRecorded.v1",
    "logistics.shipment.ShipmentCancelled.v1", "logistics.shipment.DeliveryFailed.v1",
]
FRAUD = ["fraud.enforcement.FraudSignalRaised.v1"]

CONSUMED_TOPICS: tuple[str, ...] = tuple(
    CATALOG + CUSTODY + B2C + B2B + FINANCE + LOGISTICS + FRAUD)


def _event_name(topic: str) -> str:
    return topic.split(".")[2]


def _s(p: dict[str, Any], *names: str) -> str:
    for n in names:
        v = p.get(n)
        if isinstance(v, str) and v:
            return v
    return ""


def _i(p: dict[str, Any], *names: str) -> int:
    for n in names:
        v = p.get(n)
        if isinstance(v, int) and not isinstance(v, bool):
            return v
    return 0


def _items(p: dict[str, Any]) -> list[dict[str, Any]]:
    items = p.get("items")
    if isinstance(items, list) and items:
        return [it for it in items if isinstance(it, dict)]
    return [{}]


def route(topic: str, event_id: str, p: dict[str, Any],
          ingest_ts: int) -> list[tuple[str, dict[str, Any]]]:
    """Return (table, row) pairs for a spine event — one row per ORDER/TRADE line item
    (reviewer H-4: first-item-only undercounts demand). Line rows beyond the first suffix
    the lineage event_id with #<n> so ReplacingMergeTree dedup stays exact per line.
    Deterministic on (topic, event_id, payload) — bit-for-bit replayable (FR-ANL-009)."""
    if not topic or topic.count(".") < 3:
        return []
    event = _event_name(topic)
    occurred = _i(p, "occurredAt") or ingest_ts
    base = {"event_id": event_id, "event": event, "occurred_at": occurred, "ingest_ts": ingest_ts}
    if topic in CATALOG:
        return [("dim_product", {**base,
            "gpid": _s(p, "gpid", "GPID"), "unit": _s(p, "unit"), "category": _s(p, "category")})]
    if topic in CUSTODY:
        return [("fact_custody_events", {**base,
            "ppid": _s(p, "ppid", "PPID", "parentPpid", "newPpid"),
            "gpid": _s(p, "gpid", "GPID"), "holder": _s(p, "toHolder", "holder", "currentHolder"),
            "quantity": _i(p, "quantity"), "unit": _s(p, "unit")})]
    if topic in B2C:
        return [("fact_orders", {**base,
            "event_id": event_id if i == 0 else f"{event_id}#{i}",
            "ord": _s(p, "ord", "orderId"), "buyer_did": _s(p, "buyerDid"),
            "seller_did": _s(p, "sellerDid"), "gpid": _s(item, "gpid"),
            "quantity": _i(item, "quantity"),
            "amount_poisha": _i(p, "totalAmountPoisha", "amountPoisha")})
            for i, item in enumerate(_items(p))]
    if topic in B2B:
        return [("fact_trade_orders", {**base,
            "event_id": event_id if i == 0 else f"{event_id}#{i}",
            "trd": _s(p, "trd"), "buyer_did": _s(p, "buyerDid"), "seller_did": _s(p, "sellerDid"),
            "gpid": _s(item, "gpid"), "unit_price_poisha": _i(item, "agreedUnitPricePoisha"),
            "amount_poisha": _i(p, "totalAmountPoisha", "amountPoisha")})
            for i, item in enumerate(_items(p))]
    if topic in FINANCE:
        return [("fact_settlements", {**base,
            "ref": _s(p, "esc", "wlt", "txnId"), "reference_id": _s(p, "referenceId"),
            "reference_type": _s(p, "referenceType"), "amount_poisha": _i(p, "amountPoisha")})]
    if topic in LOGISTICS:
        return [("fact_logistics", {**base,
            "shp": _s(p, "shp", "shipmentId"),
            "reference_id": _s(p, "referenceId", "orderId", "ord")})]
    if topic in FRAUD:
        raw_score = p.get("riskScore", 0.0)
        return [("fact_fraud_signals", {**base,
            "subject_did": _s(p, "subjectDid"), "reason": _s(p, "reason"),
            "risk_score": float(raw_score) if isinstance(raw_score, int | float) else 0.0})]
    return []
