package handler

import (
	"context"
	"encoding/json"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"sync"
	"time"

	"github.com/gofiber/fiber/v3"
	"github.com/gofiber/fiber/v3/middleware/adaptor"
	"github.com/redis/go-redis/v9"
	"go.elastic.co/apm/v2"
	"gorm.io/gorm"

	"github.com/dokandar/dokandar-wallet/internal/config"
	walletdb "github.com/dokandar/dokandar-wallet/internal/db"
	"github.com/dokandar/dokandar-wallet/internal/observability"
)

// MongoHealther is satisfied by observability.LogSinks.
type MongoHealther interface {
	MongoHealth(ctx context.Context) bool
}

type Ops struct {
	Settings *config.Settings
	DB       *gorm.DB
	Redis    *redis.Client
	Logs     MongoHealther
	BootTime time.Time
	DataDir  string
}

func (o *Ops) identity() fiber.Map {
	return fiber.Map{
		"service_name":   o.Settings.ServiceName,
		"code_version":   config.CodeVersion(),
		"env_version":    o.Settings.EnvVersion,
		"tenant":         o.Settings.Tenant,
		"env":            o.Settings.AppEnv,
		"uptime_seconds": int(time.Since(o.BootTime).Seconds()),
	}
}

// ----- dep probes (each wrapped in an APM span for the Service Map) ----------

type depCheck struct {
	name      string
	spanType  string
	spanSubtp string
	resource  string // destination.service.resource — "" = no destination block
	probe     func(ctx context.Context) (bool, string)
}

type depResult struct {
	name      string
	ok        bool
	latencyMS float64
	detail    string
}

func runDeps(ctx context.Context, ds []depCheck) []depResult {
	var wg sync.WaitGroup
	out := make([]depResult, len(ds))
	for i, d := range ds {
		wg.Add(1)
		go func(i int, d depCheck) {
			defer wg.Done()
			span, sctx := apm.StartSpan(ctx, "dep."+d.name, d.spanType+"."+d.spanSubtp)
			if span != nil && d.resource != "" {
				span.Context.SetDestinationService(apm.DestinationServiceSpanContext{
					Name: d.resource, Resource: d.resource,
				})
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

func round1(f float64) float64 { return float64(int(f*10+0.5)) / 10.0 }

func (o *Ops) pgCheck(ctx context.Context) (bool, string) {
	c, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	if err := walletdb.PingGorm(c, o.DB); err != nil {
		return false, err.Error()
	}
	return true, "ok"
}

func (o *Ops) redisCheck(ctx context.Context) (bool, string) {
	if o.Redis == nil {
		return false, "not_connected"
	}
	c, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	if err := o.Redis.Ping(c).Err(); err != nil {
		return false, err.Error()
	}
	return true, "PONG"
}

func (o *Ops) kafkaCheck(ctx context.Context) (bool, string) {
	if o.Settings.KafkaBootstrap == "" {
		return false, "not_configured"
	}
	d := net.Dialer{Timeout: 2 * time.Second}
	conn, err := d.DialContext(ctx, "tcp", o.Settings.KafkaBootstrap)
	if err != nil {
		return false, err.Error()
	}
	_ = conn.Close()
	return true, "metadata-ok"
}

func (o *Ops) mongoCheck(ctx context.Context) (bool, string) {
	if o.Logs != nil && o.Logs.MongoHealth(ctx) {
		return true, "ping-ok"
	}
	return false, "unreachable"
}

func (o *Ops) esCheck(ctx context.Context) (bool, string) {
	if o.Settings.ElasticSearchURL == "" {
		return false, "not_configured"
	}
	c, cancel := context.WithTimeout(ctx, 2*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(c, http.MethodGet, o.Settings.ElasticSearchURL, nil)
	if err != nil {
		return false, err.Error()
	}
	if o.Settings.ElasticSearchUsername != "" {
		req.SetBasicAuth(o.Settings.ElasticSearchUsername, o.Settings.ElasticSearchPassword)
	}
	resp, err := http.DefaultClient.Do(req)
	if err != nil {
		return false, err.Error()
	}
	_ = resp.Body.Close()
	if resp.StatusCode >= 500 {
		return false, "http_" + http.StatusText(resp.StatusCode)
	}
	return true, "reachable"
}

// ----- /ready — Postgres ONLY ------------------------------------------------

func (o *Ops) Ready(c fiber.Ctx) error {
	results := runDeps(c.Context(), []depCheck{
		{"postgres", "db", "postgresql", "postgres", o.pgCheck},
	})
	allOK := true
	deps := make([]fiber.Map, 0, len(results))
	for _, d := range results {
		deps = append(deps, fiber.Map{
			"name": d.name, "reachable": d.ok, "latency_ms": d.latencyMS, "detail": d.detail,
		})
		if !d.ok {
			allOK = false
		}
	}
	status := "ready"
	if !allOK {
		status = "not_ready"
		c.Status(fiber.StatusServiceUnavailable)
	}
	return c.JSON(fiber.Map{
		"status":       status,
		"identity":     o.identity(),
		"dependencies": deps,
	})
}

// ----- /health — full diagnostics; gates on Postgres ONLY --------------------

func (o *Ops) Health(c fiber.Ctx) error {
	results := runDeps(c.Context(), []depCheck{
		{"postgres", "db", "postgresql", "postgres", o.pgCheck},
		{"redis", "cache", "redis", "redis", o.redisCheck},
		{"kafka", "messaging", "kafka", "kafka", o.kafkaCheck},
		{"mongo_logs", "db", "mongodb", "mongodb", o.mongoCheck},
		{"elasticsearch", "db", "elasticsearch", "elasticsearch", o.esCheck},
	})

	checks := fiber.Map{}
	healthy := true
	for _, d := range results {
		checks[d.name] = fiber.Map{"ok": d.ok, "detail": d.detail}
		// Gate on Postgres ONLY. Redis/Kafka/Mongo/ES are diagnostic — they
		// buffer or degrade and must never evict the pod.
		if d.name == "postgres" && !d.ok {
			healthy = false
		}
	}
	status := "healthy"
	if !healthy {
		status = "unhealthy"
		c.Status(fiber.StatusServiceUnavailable)
	}
	return c.JSON(fiber.Map{
		"status":   status,
		"identity": o.identity(),
		"checks":   checks,
		"observability": fiber.Map{
			"apm_service_name": o.Settings.APMServiceName,
			"apm_server_url":   o.Settings.APMServerURL,
			"logs_sink_mongo":  o.Settings.MongoLogDB + "." + o.Settings.ServiceName,
			"logs_sink_es":     o.esSinkDisplay(),
		},
	})
}

func (o *Ops) esSinkDisplay() string {
	if o.Settings.ElasticSearchURL == "" {
		return "disabled"
	}
	return o.Settings.ElasticSearchURL + "/logs-app-" + o.Settings.ServiceName + "-default"
}

// ----- /data -----------------------------------------------------------------

func (o *Ops) Data(c fiber.Ctx) error {
	p := filepath.Join(o.DataDir, o.Settings.Tenant, "result.json")
	b, err := os.ReadFile(p)
	if err != nil {
		return jerr(c, fiber.StatusNotFound, "no_snapshot", "data/"+o.Settings.Tenant+"/result.json not present (run collect.sh)")
	}
	var snap map[string]any
	if err := json.Unmarshal(b, &snap); err != nil {
		// not a JSON object → contract code snapshot_parse_failed
		return jerr(c, fiber.StatusInternalServerError, "snapshot_parse_failed", "result.json is present but not valid JSON")
	}
	snap["identity"] = o.identity()
	return c.JSON(snap)
}

// ----- /metrics --------------------------------------------------------------

// Metrics recomputes the outbox-pending gauge, then serves the promhttp text
// via the Fiber net/http adaptor (the proven path).
func (o *Ops) Metrics(c fiber.Ctx) error {
	if o.DB != nil {
		ctx, cancel := context.WithTimeout(c.Context(), 1500*time.Millisecond)
		var n int64
		if err := o.DB.WithContext(ctx).Raw(`SELECT count(*) FROM outbox WHERE sent_at IS NULL`).Scan(&n).Error; err == nil {
			observability.WalletOutboxPending.WithLabelValues(observability.ServiceVal).Set(float64(n))
		}
		cancel()
	}
	return adaptor.HTTPHandler(observability.MetricsHandler())(c)
}
