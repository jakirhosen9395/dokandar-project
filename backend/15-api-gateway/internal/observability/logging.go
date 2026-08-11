// Package observability wires the three log sinks, the APM agent, and the
// Prometheus exposition. Same contract as auth.md / observability.md:
//
//	stdout  — pretty-printed JSON (indent=2)
//	Mongo   — durable forensic store (mongo_db_dokandar_application_logs.10-wallet)
//	Elastic — Kibana Discover (logs-app-10-wallet-default) on the APM-stack ES :9200
//
// Both the Mongo collection and the ES index are derived from cfg.ServiceName
// (= "10-wallet"), so no hard-coded service string appears below.
package observability

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"log/slog"
	"net/http"
	"os"
	"strings"
	"sync"
	"time"

	"go.elastic.co/apm/v2"
	"go.mongodb.org/mongo-driver/mongo"
	"go.mongodb.org/mongo-driver/mongo/options"
)

// LogSinks holds the in-process Mongo + ES log shippers. Both are
// fire-and-forget: a bounded queue + a single drainer goroutine each.
// If a sink is unreachable or its queue fills, lines are dropped silently
// — logging never blocks a request.
type LogSinks struct {
	mongoCli *mongo.Client
	esCli    *http.Client
	esURL    string
	esUser   string
	esPass   string

	mongoQ chan map[string]any
	esQ    chan map[string]any
	stop   chan struct{}
	wg     sync.WaitGroup

	svc string
}

// SinkConfig is what main wires into the logging package at startup.
type SinkConfig struct {
	ServiceName string
	MongoURI    string
	MongoDB     string
	ESURL       string
	ESUsername  string
	ESPassword  string
}

// Setup initialises slog (stdout JSON, pretty) and starts the Mongo + ES
// drainers. Returns the LogSinks handle so main can close it on shutdown.
func Setup(ctx context.Context, level string, cfg SinkConfig) (*LogSinks, error) {
	lvl := parseLevel(level)
	s := &LogSinks{
		mongoQ: make(chan map[string]any, 10_000),
		esQ:    make(chan map[string]any, 10_000),
		stop:   make(chan struct{}),
		svc:    cfg.ServiceName,
	}

	// Mongo — forensic log store; collection name == service name.
	if cfg.MongoURI != "" {
		mctx, cancel := context.WithTimeout(ctx, 3*time.Second)
		defer cancel()
		cli, err := mongo.Connect(mctx, options.Client().ApplyURI(cfg.MongoURI))
		if err == nil {
			s.mongoCli = cli
			s.wg.Add(1)
			go s.drainMongo(cfg.MongoDB)
		} else {
			fmt.Fprintf(os.Stderr, "logging: mongo connect failed: %v (sink disabled)\n", err)
		}
	}

	// Elasticsearch — bulk-POST via plain net/http (the APM-stack ES :9200).
	if cfg.ESURL != "" {
		s.esCli = &http.Client{Timeout: 5 * time.Second}
		s.esURL = strings.TrimRight(cfg.ESURL, "/")
		s.esUser, s.esPass = cfg.ESUsername, cfg.ESPassword
		s.wg.Add(1)
		go s.drainES()
	}

	// Pretty JSON handler on stdout, with the Mongo + ES side-emit hook.
	h := newPrettyJSONHandler(os.Stdout, &slog.HandlerOptions{Level: lvl}, cfg.ServiceName, s)
	slog.SetDefault(slog.New(h))
	return s, nil
}

// Close flushes and stops the drainers. Best-effort with a short timeout.
func (s *LogSinks) Close(timeout time.Duration) {
	if s == nil {
		return
	}
	close(s.stop)
	done := make(chan struct{})
	go func() { s.wg.Wait(); close(done) }()
	select {
	case <-done:
	case <-time.After(timeout):
	}
	if s.mongoCli != nil {
		_ = s.mongoCli.Disconnect(context.Background())
	}
}

// MongoHealth — used by /health (diagnostic; never gates /ready).
func (s *LogSinks) MongoHealth(ctx context.Context) bool {
	if s == nil || s.mongoCli == nil {
		return false
	}
	c, cancel := context.WithTimeout(ctx, 1500*time.Millisecond)
	defer cancel()
	return s.mongoCli.Ping(c, nil) == nil
}

func (s *LogSinks) drainMongo(db string) {
	defer s.wg.Done()
	coll := s.mongoCli.Database(db).Collection(s.svc)
	for {
		select {
		case <-s.stop:
			return
		case doc := <-s.mongoQ:
			c, cancel := context.WithTimeout(context.Background(), 5*time.Second)
			_, _ = coll.InsertOne(c, doc)
			cancel()
		}
	}
}

func (s *LogSinks) drainES() {
	defer s.wg.Done()
	index := fmt.Sprintf("logs-app-%s-default", s.svc)
	for {
		select {
		case <-s.stop:
			return
		case doc := <-s.esQ:
			body := bytes.Buffer{}
			body.WriteString("{\"create\":{}}\n")
			b, _ := json.Marshal(doc)
			body.Write(b)
			body.WriteByte('\n')
			req, _ := http.NewRequest("POST", s.esURL+"/"+index+"/_bulk", &body)
			req.Header.Set("Content-Type", "application/x-ndjson")
			if s.esUser != "" {
				req.SetBasicAuth(s.esUser, s.esPass)
			}
			resp, err := s.esCli.Do(req)
			if err == nil {
				_ = resp.Body.Close()
			}
		}
	}
}

// prettyJSONHandler renders each slog.Record as indented JSON on stdout and
// side-emits the same payload to the Mongo + ES queues. Strips the
// elasticapm_* fields when no active trace is on the record.
type prettyJSONHandler struct {
	w       *os.File
	opts    *slog.HandlerOptions
	svcName string
	sinks   *LogSinks
}

func newPrettyJSONHandler(w *os.File, opts *slog.HandlerOptions, svc string, sinks *LogSinks) *prettyJSONHandler {
	return &prettyJSONHandler{w: w, opts: opts, svcName: svc, sinks: sinks}
}

func (h *prettyJSONHandler) Enabled(_ context.Context, lvl slog.Level) bool {
	if h.opts != nil && h.opts.Level != nil {
		return lvl >= h.opts.Level.Level()
	}
	return lvl >= slog.LevelInfo
}

// authLogRecord mirrors the field shape Python's logging + python-json-logger
// emit in the auth service so Kibana/Mongo queries are portable between Python
// and Go services. Field order: asctime → name → levelname → message →
// elasticapm_* → labels.
type authLogRecord struct {
	Asctime                 string         `json:"asctime"`
	Name                    string         `json:"name"`
	Levelname               string         `json:"levelname"`
	Message                 string         `json:"message"`
	ElasticapmTransactionID string         `json:"elasticapm_transaction_id,omitempty"`
	ElasticapmTraceID       string         `json:"elasticapm_trace_id,omitempty"`
	ElasticapmServiceName   string         `json:"elasticapm_service_name,omitempty"`
	ElasticapmServiceEnv    string         `json:"elasticapm_service_environment,omitempty"`
	ElasticapmLabels        map[string]any `json:"elasticapm_labels,omitempty"`
	Extra                   map[string]any `json:"-"`
}

// MarshalJSON emits the canonical field order then appends any extra attrs.
func (a authLogRecord) MarshalJSON() ([]byte, error) {
	var buf bytes.Buffer
	buf.WriteByte('{')
	w := func(comma bool, k string, v any) bool {
		b, err := json.Marshal(v)
		if err != nil || string(b) == `""` || string(b) == "null" {
			// skip empty optional fields (matches auth's omitempty)
			if k == "asctime" || k == "name" || k == "levelname" || k == "message" {
				// required — emit anyway
			} else {
				return comma
			}
		}
		if comma {
			buf.WriteByte(',')
		}
		kb, _ := json.Marshal(k)
		buf.Write(kb)
		buf.WriteByte(':')
		buf.Write(b)
		return true
	}
	c := false
	c = w(c, "asctime", a.Asctime)
	c = w(c, "name", a.Name)
	c = w(c, "levelname", a.Levelname)
	c = w(c, "message", a.Message)
	if a.ElasticapmTransactionID != "" {
		c = w(c, "elasticapm_transaction_id", a.ElasticapmTransactionID)
		c = w(c, "elasticapm_trace_id", a.ElasticapmTraceID)
		c = w(c, "elasticapm_service_name", a.ElasticapmServiceName)
		c = w(c, "elasticapm_service_environment", a.ElasticapmServiceEnv)
		c = w(c, "elasticapm_labels", a.ElasticapmLabels)
	}
	for k, v := range a.Extra {
		c = w(c, k, v)
	}
	buf.WriteByte('}')
	return buf.Bytes(), nil
}

// levelToName maps slog.Level to Python's levelname.
func levelToName(l slog.Level) string {
	switch {
	case l >= slog.LevelError:
		return "ERROR"
	case l >= slog.LevelWarn:
		return "WARNING"
	case l >= slog.LevelInfo:
		return "INFO"
	default:
		return "DEBUG"
	}
}

func (h *prettyJSONHandler) Handle(ctx context.Context, r slog.Record) error {
	// Default logger name = "<svc>.go"; attrs can override with `name=...`.
	rec := authLogRecord{
		Asctime:   r.Time.Format("2006-01-02 15:04:05,000"), // matches Python's logging asctime
		Name:      h.svcName + ".go",
		Levelname: levelToName(r.Level),
		Message:   r.Message,
		Extra:     map[string]any{},
	}
	r.Attrs(func(a slog.Attr) bool {
		switch a.Key {
		case "name":
			rec.Name = a.Value.String()
		default:
			rec.Extra[a.Key] = a.Value.Any()
		}
		return true
	})

	// Stamp APM trace context when in scope.
	if tx := apm.TransactionFromContext(ctx); tx != nil {
		td := tx.TraceContext()
		rec.ElasticapmTransactionID = td.Span.String()
		rec.ElasticapmTraceID = td.Trace.String()
		rec.ElasticapmServiceName = h.svcName
		rec.ElasticapmServiceEnv = os.Getenv("APP_ENV")
		rec.ElasticapmLabels = map[string]any{
			"transaction.id":      td.Span.String(),
			"trace.id":            td.Trace.String(),
			"span.id":             nil,
			"service.name":        h.svcName,
			"service.environment": os.Getenv("APP_ENV"),
		}
		// ECS-compliant top-level fields so Kibana APM joins logs↔traces on trace.id
		// (the elasticapm_* fields above are not the ECS join keys). span.id when in a span.
		rec.Extra["trace"] = map[string]any{"id": td.Trace.String()}
		rec.Extra["transaction"] = map[string]any{"id": td.Span.String()}
		spanID := td.Span.String()
		if sp := apm.SpanFromContext(ctx); sp != nil {
			spanID = sp.TraceContext().Span.String()
		}
		rec.Extra["span"] = map[string]any{"id": spanID}
		rec.Extra["service"] = map[string]any{
			"name":        h.svcName,
			"version":     serviceVersion(),
			"environment": os.Getenv("APP_ENV"),
		}
	}

	// Side-emit to Mongo + ES (mongo wants the wire-shape too).
	if h.sinks != nil {
		mb, _ := rec.MarshalJSON()
		var asMap map[string]any
		_ = json.Unmarshal(mb, &asMap)
		select {
		case h.sinks.mongoQ <- asMap:
		default:
		}
		select {
		case h.sinks.esQ <- asMap:
		default:
		}
	}

	// Stdout: pretty JSON (indent 2). Use json.Indent on the raw bytes so
	// the canonical field order from MarshalJSON survives the indenting
	// step (round-tripping through map[string]any would re-sort alphabetically).
	raw, err := rec.MarshalJSON()
	if err != nil {
		return err
	}
	var pretty bytes.Buffer
	if err := json.Indent(&pretty, raw, "", "  "); err != nil {
		return err
	}
	pretty.WriteByte('\n')
	_, err = h.w.Write(pretty.Bytes())
	return err
}

func (h *prettyJSONHandler) WithAttrs(attrs []slog.Attr) slog.Handler { return h }
func (h *prettyJSONHandler) WithGroup(string) slog.Handler            { return h }

func parseLevel(s string) slog.Level {
	switch strings.ToLower(s) {
	case "debug":
		return slog.LevelDebug
	case "warn", "warning":
		return slog.LevelWarn
	case "error":
		return slog.LevelError
	default:
		return slog.LevelInfo
	}
}

func getHostname() string {
	if h, err := os.Hostname(); err == nil {
		return h
	}
	return "unknown"
}

// serviceVersion returns the ECS service.version — the APM service version env the agent
// uses, falling back to CODE_VERSION / SERVICE_NAME so the field is never empty.
func serviceVersion() string {
	for _, k := range []string{"ELASTIC_APM_SERVICE_VERSION", "CODE_VERSION", "SERVICE_NAME"} {
		if v := os.Getenv(k); v != "" {
			return v
		}
	}
	return "unknown"
}
