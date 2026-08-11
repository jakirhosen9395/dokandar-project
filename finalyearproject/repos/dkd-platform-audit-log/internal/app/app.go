package app

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"

	"log/slog"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/config"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/httpx"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/ingest"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/obs"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/security"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/store"

	dkdplatform "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

// App is the dependency-injection container. As the R6 OHS audit sink it CONSUMES the spine and
// appends to a WORM store; it never produces events.
type App struct {
	cfg      *config.Config
	log      *slog.Logger
	metrics  *obs.Metrics
	server   *httpx.Server
	store    *store.Postgres
	consumer  *consumer.Consumer
	traceStop func(context.Context) error
	wg        sync.WaitGroup
	ready    atomic.Bool
}

func New(cfg *config.Config, log *slog.Logger) (*App, error) {
	metrics := obs.NewMetrics()
	auth := security.New(cfg.JWTIssuer, nil) // platform JWKS verifier wired at integration point
	a := &App{cfg: cfg, log: log, metrics: metrics}
	a.server = httpx.New(cfg.ServiceName, cfg.HTTPPort, cfg.MetricsPort, log, metrics, auth, a.isReady)
	return a, nil
}

func (a *App) isReady() bool { return a.ready.Load() }

// topics is the canonical spine (AllTopics) plus any operator-supplied extra verification topics.
func (a *App) topics() []string {
	return append(dkdplatform.AllTopics(), a.cfg.ExtraTopicList()...)
}

// Start brings HTTP up immediately (so health/live answer), then connects the DB and Kafka. It flips
// /ready true ONLY after the DB is connected + migrated AND the broker is reachable.
func (a *App) Start(ctx context.Context) error {
	// AUD-02: install the real OTel tracer provider (record-only when DKD_OTLP_ENDPOINT unset).
	_, a.traceStop = obs.InitTracer(ctx, a.cfg.ServiceName, a.cfg.OtlpEndpoint)

	a.server.Start()

	st, err := store.Open(ctx, a.cfg.DBDSN)
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	a.store = st
	if err := st.Migrate(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}

	ing := ingest.New(st, a.metrics, a.log, nil)
	topics := a.topics()
	cons, err := consumer.New(
		consumer.Config{Brokers: a.cfg.Brokers(), Group: a.cfg.ConsumerGroup, Topics: topics},
		a.log, ing.Handle, ing.Park,
	)
	if err != nil {
		return fmt.Errorf("build consumer: %w", err)
	}
	a.consumer = cons
	if err := cons.Ping(ctx); err != nil {
		return fmt.Errorf("kafka ping: %w", err)
	}

	a.wg.Add(1)
	go func() { defer a.wg.Done(); cons.Run(ctx) }()
	a.ready.Store(true)
	a.log.Info("audit sink started; subscribed to spine",
		"service", a.cfg.ServiceName, "group", a.cfg.ConsumerGroup, "topics", len(topics))
	return nil
}

func (a *App) Stop(ctx context.Context) error {
	a.ready.Store(false)
	if a.consumer != nil {
		a.consumer.Close()
		a.wg.Wait()
		if a.traceStop != nil {
			_ = a.traceStop(ctx)
		} // drain the consume loop before closing the DB pool (avoids a Stop/Run race)
	}
	if a.store != nil {
		a.store.Close()
	}
	return a.server.Stop(ctx)
}
