// Package ops implements the contract endpoints: /ready /health /data.
// (Metrics is wired separately via promhttp.) Each _check_* is wrapped in
// an APM span with destination.service.* so Kibana → Dependencies populates.
package ops

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/jackc/pgx/v5/pgxpool"
	"github.com/redis/go-redis/v9"
	"github.com/segmentio/kafka-go"
	"go.elastic.co/apm/v2"

	"github.com/dokandar/dokandar-profile/internal/app"
	"github.com/dokandar/dokandar-profile/internal/domain/outbox"
	"github.com/dokandar/dokandar-profile/internal/observability"
)

type Handler struct {
	ServiceName  string
	CodeVersion  string
	EnvVersion   string
	Tenant       string
	Env          string
	BootTime     time.Time

	PG          *pgxpool.Pool
	Redis       *redis.Client
	Logs        *observability.LogSinks
	KafkaBroker string
	APMURL      string
	APMSvcName  string
	LogsMongoDB string
	LogsESURL   string

	// MediaGRPCAddr is host:port for the Media gRPC service. Empty when
	// Media isn't deployed — /health.checks.grpc_media still emits a
	// diagnostic entry (ok=false, detail="not_configured").
	MediaGRPCAddr string

	DataDir string

	Outbox *outbox.Store
}

type depResult struct {
	name     string
	ok       bool
	latencyMS float64
	detail   string
}

// Identity is the platform-standard service-fingerprint block reused
// across /ready and /health. Field order matches the spec: name first,
// version, env shape, then runtime uptime.
type Identity struct {
	ServiceName   string `json:"service_name"`
	CodeVersion   string `json:"code_version"`
	EnvVersion    string `json:"env_version"`
	Tenant        string `json:"tenant"`
	Env           string `json:"env"`
	UptimeSeconds int    `json:"uptime_seconds"`
}

// Dep — one row inside /ready.dependencies[].
type Dep struct {
	Name      string  `json:"name"`
	Reachable bool    `json:"reachable"`
	LatencyMS float64 `json:"latency_ms"`
}

// Check — one entry inside /health.checks{}.
type Check struct {
	OK     bool   `json:"ok"`
	Detail string `json:"detail"`
}

type ReadyBody struct {
	Status       string   `json:"status"`
	Identity     Identity `json:"identity"`
	Dependencies []Dep    `json:"dependencies"`
}

type HealthObservability struct {
	APMServiceName string `json:"apm_service_name"`
	APMServerURL   string `json:"apm_server_url"`
	LogsSinkMongo  string `json:"logs_sink_mongo"`
	LogsSinkES     string `json:"logs_sink_es"`
}

// HealthBody preserves field order: status → identity → checks → observability.
// `checks` is a marshal-helper that emits its keys in a fixed order
// (postgres, redis, kafka, mongo_logs, apm, s3_kyc, grpc_media) — see
// MarshalJSON below.
type HealthBody struct {
	Status        string              `json:"status"`
	Identity      Identity            `json:"identity"`
	Checks        OrderedChecks       `json:"checks"`
	Observability HealthObservability `json:"observability"`
}

type OrderedChecks struct {
	Postgres  *Check `json:"-"`
	Redis     *Check `json:"-"`
	Kafka     *Check `json:"-"`
	Rabbitmq  *Check `json:"-"`
	MongoLogs *Check `json:"-"`
	APM       *Check `json:"-"`
	S3KYC     *Check `json:"-"`
	GRPCMedia *Check `json:"-"`
}

// MarshalJSON emits the checks in the canonical platform order so logs +
// dashboards always see the same shape, regardless of which subset the
// service populates.
func (o OrderedChecks) MarshalJSON() ([]byte, error) {
	pairs := []struct {
		key string
		v   *Check
	}{
		{"postgres", o.Postgres},
		{"redis", o.Redis},
		{"kafka", o.Kafka},
		{"rabbitmq", o.Rabbitmq},
		{"mongo_logs", o.MongoLogs},
		{"apm", o.APM},
		{"s3_kyc", o.S3KYC},
		{"grpc_media", o.GRPCMedia},
	}
	var buf bytes.Buffer
	buf.WriteByte('{')
	first := true
	for _, p := range pairs {
		if p.v == nil {
			continue
		}
		if !first {
			buf.WriteByte(',')
		}
		first = false
		k, _ := json.Marshal(p.key)
		buf.Write(k)
		buf.WriteByte(':')
		b, err := json.Marshal(p.v)
		if err != nil {
			return nil, err
		}
		buf.Write(b)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

func (h *Handler) identity(now time.Time) Identity {
	return Identity{
		ServiceName:   h.ServiceName,
		CodeVersion:   h.CodeVersion,
		EnvVersion:    h.EnvVersion,
		Tenant:        h.Tenant,
		Env:           h.Env,
		UptimeSeconds: int(now.Sub(h.BootTime).Seconds()),
	}
}

// Ready — traffic-gating deps only.
func (h *Handler) Ready(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	results := runDepsConcurrent(ctx, []depCheck{
		{"postgres", "db", "postgresql", "postgres", func(c context.Context) (bool, string) { return h.pgCheck(c) }},
		{"redis", "cache", "redis", "redis", func(c context.Context) (bool, string) { return h.redisCheck(c) }},
	})
	allOK := true
	deps := make([]Dep, 0, len(results))
	for _, d := range results {
		deps = append(deps, Dep{Name: d.name, Reachable: d.ok, LatencyMS: d.latencyMS})
		if !d.ok {
			allOK = false
		}
	}
	status := http.StatusOK
	state := "ready"
	if !allOK {
		status = http.StatusServiceUnavailable
		state = "not_ready"
	}
	app.PrettyJSON(w, status, ReadyBody{
		Status:       state,
		Identity:     h.identity(time.Now()),
		Dependencies: deps,
	})
}

// Health — full diagnostic view: spec §11 checks + identity + observability.
func (h *Handler) Health(w http.ResponseWriter, r *http.Request) {
	ctx := r.Context()
	results := runDepsConcurrent(ctx, []depCheck{
		{"postgres", "db", "postgresql", "postgres", func(c context.Context) (bool, string) { return h.pgCheck(c) }},
		{"redis", "cache", "redis", "redis", func(c context.Context) (bool, string) { return h.redisCheck(c) }},
		{"kafka", "messaging", "kafka", "kafka", func(c context.Context) (bool, string) { return h.kafkaCheck(c) }},
		{"mongo_logs", "db", "mongodb", "mongodb", func(c context.Context) (bool, string) { return h.mongoCheck(c) }},
		{"apm", "external", "apm", "", func(c context.Context) (bool, string) { return h.apmCheck(c) }},
		{"grpc_media", "external", "grpc", "media", func(c context.Context) (bool, string) { return h.grpcMediaCheck(c) }},
	})

	checks := OrderedChecks{}
	healthy := true
	for _, d := range results {
		c := &Check{OK: d.ok, Detail: d.detail}
		switch d.name {
		case "postgres":
			checks.Postgres = c
		case "redis":
			checks.Redis = c
		case "kafka":
			checks.Kafka = c
		case "mongo_logs":
			checks.MongoLogs = c
		case "apm":
			checks.APM = c
		case "grpc_media":
			checks.GRPCMedia = c
			continue // diagnostic only — doesn't flip overall state
		}
		if !d.ok {
			healthy = false
		}
	}
	status := http.StatusOK
	state := "healthy"
	if !healthy {
		status = http.StatusServiceUnavailable
		state = "unhealthy"
	}
	app.PrettyJSON(w, status, HealthBody{
		Status:   state,
		Identity: h.identity(time.Now()),
		Checks:   checks,
		Observability: HealthObservability{
			APMServiceName: h.APMSvcName,
			APMServerURL:   h.APMURL,
			LogsSinkMongo:  fmt.Sprintf("mongodb://%s/%s", h.LogsMongoDB, h.ServiceName),
			LogsSinkES:     h.esSinkDisplay(),
		},
	})
}

func (h *Handler) esSinkDisplay() string {
	if h.LogsESURL == "" {
		return "disabled"
	}
	return fmt.Sprintf("%s/logs-app-%s-*", h.LogsESURL, h.ServiceName)
}

// Data — fleet convention (matches auth/search/...): serve the tenant's
// collect.sh snapshot, i.e. data/<tenant>/result.json (host/EC2 baseline for
// tenant `cloud`, local-machine baseline for `local`). 404 no_snapshot if it
// hasn't been generated yet; 500 snapshot_parse_failed if present but invalid.
// The data/ dir is bind-mounted, so re-running collect.sh refreshes the
// response with no container restart.
func (h *Handler) Data(w http.ResponseWriter, r *http.Request) {
	f := filepath.Join(h.DataDir, h.Tenant, "result.json")
	b, err := os.ReadFile(f)
	if err != nil {
		app.WriteError(w, r, http.StatusNotFound, "no_snapshot",
			fmt.Sprintf("data/%s/result.json not present (run data/%s/collect.sh)", h.Tenant, h.Tenant), nil)
		return
	}
	if !json.Valid(b) {
		app.WriteError(w, r, http.StatusInternalServerError, "snapshot_parse_failed",
			"data/"+h.Tenant+"/result.json is present but not valid JSON", nil)
		return
	}
	// identity block first, then the collect.sh snapshot fields (spliced so
	// collect.sh's key order is preserved; PrettyJSON re-indents to 2-space).
	idJSON, _ := json.Marshal(h.identity(time.Now()))
	rest := bytes.TrimSpace(bytes.TrimSpace(b)[1:]) // after the snapshot's leading '{'
	merged := append([]byte(`{"identity":`), idJSON...)
	if len(rest) > 0 && rest[0] != '}' {
		merged = append(merged, ',')
	}
	merged = append(merged, rest...)
	app.PrettyJSON(w, http.StatusOK, json.RawMessage(merged))
}

// ---- dep check internals -----------------------------------------------

type depCheck struct {
	name      string
	spanType  string
	spanSubtp string
	resource  string // destination.service.resource — "" means no destination block (e.g. apm)
	probe     func(context.Context) (bool, string)
}

func runDepsConcurrent(ctx context.Context, ds []depCheck) []depResult {
	var wg sync.WaitGroup
	out := make([]depResult, len(ds))
	for i, d := range ds {
		wg.Add(1)
		go func(i int, d depCheck) {
			defer wg.Done()
			span, sctx := apm.StartSpan(ctx, "dep."+d.name, d.spanType+"."+d.spanSubtp)
			if span != nil {
				if d.resource != "" {
					span.Context.SetDestinationService(apm.DestinationServiceSpanContext{
						Name:     d.resource,
						Resource: d.resource,
					})
				}
			}
			t := time.Now()
			ok, detail := d.probe(sctx)
			lat := float64(time.Since(t).Microseconds()) / 1000.0
			if span != nil {
				span.End()
			}
			out[i] = depResult{name: d.name, ok: ok, latencyMS: round1(lat), detail: detail}
		}(i, d)
	}
	wg.Wait()
	return out
}

func round1(f float64) float64 {
	return float64(int(f*10+0.5)) / 10.0
}

func (h *Handler) pgCheck(ctx context.Context) (bool, string) {
	c, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := h.PG.Ping(c); err != nil {
		return false, err.Error()
	}
	return true, "ok"
}

func (h *Handler) redisCheck(ctx context.Context) (bool, string) {
	c, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	if err := h.Redis.Ping(c).Err(); err != nil {
		return false, err.Error()
	}
	return true, "PONG"
}

func (h *Handler) kafkaCheck(ctx context.Context) (bool, string) {
	c, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	conn, err := kafka.DialContext(c, "tcp", h.KafkaBroker)
	if err != nil {
		return false, err.Error()
	}
	_ = conn.Close()
	return true, "metadata-ok"
}

func (h *Handler) mongoCheck(ctx context.Context) (bool, string) {
	if h.Logs != nil && h.Logs.MongoHealth(ctx) {
		return true, "ping-ok"
	}
	return false, "unreachable"
}

func (h *Handler) apmCheck(_ context.Context) (bool, string) {
	ok, detail := observability.APMServerReachable(h.APMURL, 1500*time.Millisecond)
	return ok, detail
}

// grpcMediaCheck — diagnostic probe for the Media gRPC service. Returns
// {ok:false, detail:"not_configured"} when MEDIA_GRPC_ADDR is unset (Media
// isn't deployed yet); otherwise opens a 1.5s TCP probe to the address.
func (h *Handler) grpcMediaCheck(_ context.Context) (bool, string) {
	if h.MediaGRPCAddr == "" {
		return false, "not_configured"
	}
	d := net.Dialer{Timeout: 1500 * time.Millisecond}
	conn, err := d.Dial("tcp", h.MediaGRPCAddr)
	if err != nil {
		return false, err.Error()
	}
	_ = conn.Close()
	return true, h.MediaGRPCAddr + " tcp-ok"
}
