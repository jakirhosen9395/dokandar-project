// Package app wires provenance-svc: Neo4j graph client, the custody projection consumer, and
// the read-only REST surface. No store, no outbox — context #4 owns nothing on the spine.
package app

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/provenance-svc/internal/api"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/config"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/graph"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/httpx"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/obs"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/projection"
	"gitlab.com/final-year-project3354127/provenance-svc/internal/security"
)

type App struct {
	cfg     config.Config
	log     *slog.Logger
	metrics *obs.Metrics
	server  *httpx.Server
	g       *graph.Client
	cons      *consumer.Consumer
	traceStop func(context.Context) error
	wg        sync.WaitGroup
	ready   atomic.Bool
}

func New(cfg config.Config, log *slog.Logger) *App {
	return &App{cfg: cfg, log: log, metrics: obs.NewMetrics()}
}

func (a *App) isReady() bool { return a.ready.Load() }

func (a *App) Start(ctx context.Context) error {
	// PRV-07: install the real OTel tracer provider (record-only when DKD_OTLP_ENDPOINT unset).
	_, a.traceStop = obs.InitTracer(ctx, a.cfg.ServiceName, a.cfg.OtlpEndpoint)

	g, err := graph.New(a.cfg.Neo4jURI, a.cfg.Neo4jUser, a.cfg.Neo4jPassword)
	if err != nil {
		return fmt.Errorf("neo4j client: %w", err)
	}
	a.g = g
	if err := g.Ping(ctx); err != nil {
		return fmt.Errorf("neo4j ping: %w", err)
	}

	apiH := api.New(g, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() })
	auth := security.New(a.cfg.JWTIssuer, nil)
	a.server = httpx.New(a.cfg.ServiceName, a.cfg.HTTPPort, a.cfg.MetricsPort,
		a.log, a.metrics, auth, a.isReady, apiH.Register)
	if err := a.server.Start(); err != nil {
		return fmt.Errorf("http listeners: %w", err)
	}

	proj := projection.New(g, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() })
	cons, err := consumer.New(
		consumer.Config{Brokers: a.cfg.Brokers(), Group: a.cfg.ConsumerGroup, Topics: projection.Topics()},
		a.log, proj.Handle, proj.Park,
	)
	if err != nil {
		return fmt.Errorf("build consumer: %w", err)
	}
	a.cons = cons
	if err := cons.Ping(ctx); err != nil {
		return fmt.Errorf("kafka ping: %w", err)
	}

	a.wg.Add(1)
	go func() { defer a.wg.Done(); cons.Run(ctx) }()
	a.ready.Store(true)
	a.log.Info("provenance-svc started (R1 read-side graph projection)", "neo4j", a.cfg.Neo4jURI)
	return nil
}

func (a *App) Stop(ctx context.Context) error {
	a.ready.Store(false)
	if a.cons != nil {
		a.cons.Close()
	}
	if a.traceStop != nil {
		_ = a.traceStop(ctx)
	}
	a.wg.Wait()
	if a.g != nil {
		if err := a.g.Close(ctx); err != nil {
			a.log.Warn("neo4j driver close error", "err", err)
		}
	}
	if a.server != nil {
		return a.server.Stop(ctx)
	}
	return nil
}
