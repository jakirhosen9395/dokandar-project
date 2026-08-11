package com.dokandar.review.observability

import io.prometheus.client.CollectorRegistry
import io.prometheus.client.Counter
import io.prometheus.client.Gauge
import io.prometheus.client.Histogram
import io.prometheus.client.exporter.common.TextFormat
import java.io.StringWriter

object Metrics {
    const val SVC = "08-review"
    val registry: CollectorRegistry = CollectorRegistry.defaultRegistry
    val httpRequests: Counter = Counter.build("http_requests_total", "HTTP requests").labelNames("method", "route", "status").register()
    val httpDuration: Histogram = Histogram.build("http_request_duration_seconds", "HTTP latency").labelNames("method", "route").register()
    val reviewPosts: Counter = Counter.build("review_posts_total", "review posts").labelNames("service", "result").register()
    val reviewVotes: Counter = Counter.build("review_votes_total", "review votes").labelNames("service").register()
    val reviewReports: Counter = Counter.build("review_reports_total", "review reports").labelNames("service", "reason").register()
    val reviewHidden: Counter = Counter.build("review_hidden_total", "auto-hides").labelNames("service").register()
    val reviewAggUpdates: Counter = Counter.build("review_aggregate_updates_total", "rating_aggregates upserts").labelNames("service").register()
    val reviewKafka: Counter = Counter.build("review_kafka_messages_total", "projector messages").labelNames("service", "topic", "result").register()
    val outboxPublished: Counter = Counter.build("review_outbox_published_total", "outbox rows published").labelNames("service").register()
    val outboxPending: Gauge = Gauge.build("review_outbox_pending", "unsent outbox rows").labelNames("service").register()

    fun render(): String { val w = StringWriter(); TextFormat.write004(w, registry.metricFamilySamples()); return w.toString() }
}
