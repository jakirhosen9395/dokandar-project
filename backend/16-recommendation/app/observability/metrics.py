from __future__ import annotations
from prometheus_client import Counter, Gauge, Histogram

SERVICE_VAL = "16-recommendation"

reco_feed_served_total = Counter("reco_feed_served_total", "Personalized feeds served.", ("service","source"))
reco_similar_served_total = Counter("reco_similar_served_total", "Item-similar served.", ("service",))
reco_cross_sell_served_total = Counter("reco_cross_sell_served_total", "Cross-sell served.", ("service",))
reco_cache_hit_total = Counter("reco_cache_hit_total", "Redis cache hits.", ("service",))
reco_interactions_ingested_total = Counter("reco_interactions_ingested_total", "Interactions ingested.", ("service","kind"))
reco_retrain_total = Counter("reco_retrain_total", "Retrains triggered.", ("service","result"))

# Spec-named business metrics (architecture §8.4) — closed-set labels only (strategy/result).
recommendation_feed_total = Counter("recommendation_feed_total", "Feeds served per strategy.", ("service","strategy"))
recommendation_fallback_total = Counter("recommendation_fallback_total", "Popularity/trending fallback served (vector store cold/down).", ("service",))
recommendation_retrain_total = Counter("recommendation_retrain_total", "Retrains by result.", ("service","result"))
recommendation_ann_latency_ms = Histogram("recommendation_ann_latency_ms", "Qdrant ANN lookup latency (ms).", ("service",),
                                           buckets=(1, 5, 10, 25, 50, 100, 250, 500, 1000))
