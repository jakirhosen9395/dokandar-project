// Prometheus counters/gauges for the wallet service. Hand-rolled registry,
// closed-set labels only — keeps cardinality bounded. RED metrics come from
// the Fiber middleware; the wallet_* surface is the ledger-domain detail.
//
// The exact metric names + labels here are part of the acceptance contract
// (the smoke test greps for each). Do not rename without updating test.sh.
package observability

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

// ServiceVal is the closed-set `service` label value on every wallet_* metric
// and the http_requests_total series. Must equal SERVICE_NAME.
const ServiceVal = "10-wallet"

var (
	// RED — HTTP request counter. status is a closed-set token (2xx/4xx/5xx),
	// route is the matched route pattern (never a raw path / UUID).
	HTTPRequestsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests served, by method + route + status.",
	}, []string{"service", "method", "route", "status"})

	HTTPRequestDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request duration histogram.",
		Buckets: prometheus.DefBuckets,
	}, []string{"service", "method", "route"})

	// Ledger-domain counters.
	WalletCreditsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "wallet_credits_total",
		Help: "Wallet credit ledger posts, by kind.",
	}, []string{"service", "kind"})

	WalletDebitsTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "wallet_debits_total",
		Help: "Wallet debit ledger posts, by kind.",
	}, []string{"service", "kind"})

	WalletCashbackGranted = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "wallet_cashback_granted_total",
		Help: "Cashback grants applied from order.placed events.",
	}, []string{"service"})

	WalletInsufficient = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "wallet_insufficient_balance_total",
		Help: "Debit attempts rejected for insufficient available balance.",
	}, []string{"service"})

	// Outbox gauge (mandated: every outbox service exposes <svc>_outbox_pending).
	WalletOutboxPending = prometheus.NewGaugeVec(prometheus.GaugeOpts{
		Name: "wallet_outbox_pending",
		Help: "Outbox rows awaiting Kafka relay (sent_at IS NULL).",
	}, []string{"service"})

	WalletOutboxPublishedTotal = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "wallet_outbox_published_total",
		Help: "Outbox rows successfully shipped to Kafka.",
	}, []string{"service"})
)

func init() {
	prometheus.MustRegister(
		HTTPRequestsTotal,
		HTTPRequestDuration,
		WalletCreditsTotal,
		WalletDebitsTotal,
		WalletCashbackGranted,
		WalletInsufficient,
		WalletOutboxPending,
		WalletOutboxPublishedTotal,
	)
	// Pre-create the zero series so each metric's HELP/TYPE + a series line
	// appears in /metrics from boot — client_golang omits a Vec entirely until
	// a label combination is observed once, and the smoke greps the names
	// before any ledger op runs (and a Kafka-less run never ships the outbox).
	// (http_requests_total is left alone — real traffic populates it with a
	// real route label; a placeholder would inject a bogus series.)
	WalletCreditsTotal.WithLabelValues(ServiceVal, "topup")
	WalletDebitsTotal.WithLabelValues(ServiceVal, "order_payment")
	WalletCashbackGranted.WithLabelValues(ServiceVal)
	WalletInsufficient.WithLabelValues(ServiceVal)
	WalletOutboxPending.WithLabelValues(ServiceVal)
	WalletOutboxPublishedTotal.WithLabelValues(ServiceVal)
}

// MetricsHandler returns the standard promhttp handler — wired at /metrics.
func MetricsHandler() http.Handler { return promhttp.Handler() }
