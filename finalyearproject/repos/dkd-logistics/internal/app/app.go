// Package app wires logistics-svc: dkd_logistics Postgres, the shipment state machine, the custody
// POD-attestation client, and the transactional outbox relay producing the 6 logistics.shipment.*
// topics (+ inbox dedup on consumed order/custody facts). (LOG-09)
package app

import (
	"context"
	"fmt"
	"sync"
	"sync/atomic"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/api"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/rabbit"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/clients"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/config"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/httpx"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/obs"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/outbox"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/projection"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/security"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/store"
)

type App struct {
	cfg     config.Config
	log     *slog.Logger
	metrics *obs.Metrics
	server  *httpx.Server
	store     *store.Store
	cons      *consumer.Consumer
	relay     *outbox.Relay
	rabbit    *rabbit.Publisher
	traceStop func(context.Context) error
	wg        sync.WaitGroup
	ready     atomic.Bool
}

func New(cfg config.Config, log *slog.Logger) *App {
	return &App{cfg: cfg, log: log, metrics: obs.NewMetrics()}
}

func (a *App) isReady() bool { return a.ready.Load() }

func (a *App) Start(ctx context.Context) error {
	// LOG-07: install the real OTel tracer provider (record-only when DKD_OTLP_ENDPOINT is unset).
	_, a.traceStop = obs.InitTracer(ctx, a.cfg.ServiceName, a.cfg.OtlpEndpoint)

	st, err := store.Open(ctx, a.cfg.DSN())
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	a.store = st
	if err := st.Migrate(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}

	cl := clients.New(a.cfg.B2CURL, a.cfg.CustodyURL, a.cfg.AttestationPrivKey, a.log)
	pub, err := rabbit.New(a.cfg.RabbitURL) // LOG-10 intra-context queues (no-op if unset)
	if err != nil {
		return fmt.Errorf("rabbitmq connect: %w", err)
	}
	a.rabbit = pub
	apiH := api.New(st, cl, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() }, pub)
	auth := security.New(a.cfg.JWTIssuer, nil)
	a.server = httpx.New(a.cfg.ServiceName, a.cfg.HTTPPort, a.cfg.MetricsPort,
		a.log, a.metrics, auth, a.isReady, apiH.Register)
	if err := a.server.Start(); err != nil {
		return fmt.Errorf("http listeners: %w", err)
	}

	relay, err := outbox.New(a.cfg.Brokers(), st, a.log, a.metrics)
	if err != nil {
		return fmt.Errorf("build relay: %w", err)
	}
	a.relay = relay
	a.wg.Add(1)
	go func() { defer a.wg.Done(); relay.Run(ctx) }()

	proj := projection.New(st, cl, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() })
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
	a.log.Info("logistics-svc started (R1 read-side + G2 strong-local seam)", "db", a.cfg.DBName)
	return nil
}

func (a *App) Stop(ctx context.Context) error {
	a.ready.Store(false)
	// Drain in-flight HTTP handlers BEFORE tearing down the pool they depend on;
	// the store closes last so nothing races a closed pool (reviewer H-1).
	var serverErr error
	if a.server != nil {
		serverErr = a.server.Stop(ctx)
	}
	if a.cons != nil {
		a.cons.Close()
	}
	if a.traceStop != nil {
		_ = a.traceStop(ctx)
	}
	if a.relay != nil {
		a.relay.Close()
	}
	if a.rabbit != nil {
		a.rabbit.Close()
	}
	a.wg.Wait()
	if a.store != nil {
		a.store.Close()
	}
	return serverErr
}
