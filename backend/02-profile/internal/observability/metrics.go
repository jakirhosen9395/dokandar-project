// Prometheus counters/gauges for the profile service. Hand-rolled,
// closed-set labels — keeps cardinality bounded. RED metrics come from
// chi middleware; this file is just the service-specific surface.
package observability

import (
	"net/http"

	"github.com/prometheus/client_golang/prometheus"
	"github.com/prometheus/client_golang/prometheus/promhttp"
)

var (
	ProfileShellsCreated = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "profile_shells_created_total",
		Help: "Empty profile rows upserted from a dokandar.user.created event.",
	})
	ProfileGet = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "profile_get_total",
		Help: "GET /me — by outcome (ok|not_found|error).",
	}, []string{"result"})
	ProfilePatch = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "profile_patch_total",
		Help: "PATCH /me — by outcome.",
	}, []string{"result"})
	ProfileReads = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "profile_reads_total",
		Help: "GET /me requests served, by cache hit/miss.",
	}, []string{"source"})
	AddressesAdded = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "profile_addresses_created_total",
		Help: "Address rows inserted via POST /me/addresses.",
	})
	AddressesDeleted = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "profile_addresses_deleted_total",
		Help: "Address rows soft-deleted via DELETE /me/addresses/{id}.",
	})
	DefaultAddressChanges = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "profile_addresses_default_changed_total",
		Help: "Successful POST /me/addresses/{id}/default invocations.",
	})
	KycMirrorUpdates = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "profile_kyc_mirror_updates_total",
		Help: "kyc mirror updates from the auth.kyc.* topics, by old→new.",
	}, []string{"from", "to"})
	GrpcLookup = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "profile_grpc_lookup_total",
		Help: "gRPC LookupProfile calls — by outcome.",
	}, []string{"outcome"})
	OutboxPending = prometheus.NewGauge(prometheus.GaugeOpts{
		Name: "profile_outbox_pending",
		Help: "Outbox rows awaiting Kafka relay.",
	})
	OutboxRelayed = prometheus.NewCounter(prometheus.CounterOpts{
		Name: "profile_outbox_relayed_total",
		Help: "Outbox rows successfully shipped to Kafka.",
	})

	HTTPRequests = prometheus.NewCounterVec(prometheus.CounterOpts{
		Name: "http_requests_total",
		Help: "HTTP requests served, by route + method + status.",
	}, []string{"method", "route", "status"})

	HTTPDuration = prometheus.NewHistogramVec(prometheus.HistogramOpts{
		Name:    "http_request_duration_seconds",
		Help:    "HTTP request duration histogram.",
		Buckets: prometheus.DefBuckets,
	}, []string{"method", "route"})
)

func init() {
	prometheus.MustRegister(
		ProfileShellsCreated, ProfileGet, ProfilePatch, ProfileReads,
		AddressesAdded, AddressesDeleted, DefaultAddressChanges,
		KycMirrorUpdates, GrpcLookup,
		OutboxPending, OutboxRelayed,
		HTTPRequests, HTTPDuration,
	)
}

// Handler returns the standard promhttp handler — wired at /metrics.
func MetricsHandler() http.Handler { return promhttp.Handler() }
