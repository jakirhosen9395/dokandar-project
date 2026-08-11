// Package app wires catalog-svc: Postgres (dkd_catalog) + tx-outbox relay to the Kafka spine,
// the M5 custody projection consumer, OpenSearch-backed search, and the REST /v1 surface.
// /ready flips true ONLY after the DB is migrated and the broker answers pings.
package app

import (
	"context"
	"fmt"
	"net"
	"sync"
	"sync/atomic"
	"time"

	"log/slog"

	"google.golang.org/grpc"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/api"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/config"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/grpcohs"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/grpcohs/pb"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/httpx"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/obs"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/outbox"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/projection"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/search"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/security"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/store"
)

type App struct {
	cfg     config.Config
	log     *slog.Logger
	metrics *obs.Metrics
	server  *httpx.Server
	store   *store.Store
	relay   *outbox.Relay
	cons      *consumer.Consumer
	grpcSrv   *grpc.Server
	traceStop func(context.Context) error
	wg        sync.WaitGroup
	ready   atomic.Bool
}

func New(cfg config.Config, log *slog.Logger) *App {
	return &App{cfg: cfg, log: log, metrics: obs.NewMetrics()}
}

func (a *App) isReady() bool { return a.ready.Load() }

func (a *App) Start(ctx context.Context) error {
	// CAT-06: install the real OTel tracer provider (record-only when DKD_OTLP_ENDPOINT unset).
	_, a.traceStop = obs.InitTracer(ctx, a.cfg.ServiceName, a.cfg.OtlpEndpoint)

	st, err := store.Open(ctx, a.cfg.DSN())
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	a.store = st
	if err := st.Migrate(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}

	se := search.New(a.cfg.SearchURL, a.cfg.SearchIndex)
	apiH := api.New(st, se, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() })
	auth := security.New(a.cfg.JWTIssuer, nil) // platform JWKS verifier wired at integration point
	a.server = httpx.New(a.cfg.ServiceName, a.cfg.HTTPPort, a.cfg.MetricsPort,
		a.log, a.metrics, auth, a.isReady, apiH.Register)
	if err := a.server.Start(); err != nil {
		return fmt.Errorf("http listeners: %w", err)
	}

	relay, err := outbox.New(a.cfg.Brokers(), st, a.log, a.metrics)
	if err != nil {
		return fmt.Errorf("build outbox relay: %w", err)
	}
	a.relay = relay
	if err := relay.Ping(ctx); err != nil {
		return fmt.Errorf("kafka ping (producer): %w", err)
	}

	m5 := projection.New(st, a.metrics, a.log)
	cons, err := consumer.New(
		consumer.Config{Brokers: a.cfg.Brokers(), Group: a.cfg.ConsumerGroup, Topics: projection.Topics()},
		a.log, m5.Handle, m5.Park,
	)
	if err != nil {
		return fmt.Errorf("build consumer: %w", err)
	}
	a.cons = cons
	if err := cons.Ping(ctx); err != nil {
		return fmt.Errorf("kafka ping (consumer): %w", err)
	}

	// CAT-01 / R7: expose the Product read-model over gRPC (the internal OHS plane).
	lis, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", a.cfg.GrpcPort))
	if err != nil {
		return fmt.Errorf("grpc listen: %w", err)
	}
	a.grpcSrv = grpc.NewServer()
	pb.RegisterCatalogProductOhsServer(a.grpcSrv, grpcohs.New(st))

	a.wg.Add(3)
	go func() { defer a.wg.Done(); relay.Run(ctx) }()
	go func() { defer a.wg.Done(); cons.Run(ctx) }()
	go func() {
		defer a.wg.Done()
		if err := a.grpcSrv.Serve(lis); err != nil {
			a.log.Warn("grpc server stopped", "err", err.Error())
		}
	}()
	a.log.Info("catalog gRPC OHS listening", "port", a.cfg.GrpcPort)
	a.ready.Store(true)
	a.log.Info("catalog-svc started (R7 master-data OHS)",
		"service", a.cfg.ServiceName, "db", a.cfg.DBName, "group", a.cfg.ConsumerGroup,
		"search", se.Enabled())
	return nil
}

func (a *App) Stop(ctx context.Context) error {
	a.ready.Store(false)
	if a.cons != nil {
		a.cons.Close()
	}
	if a.grpcSrv != nil {
		a.grpcSrv.GracefulStop()
	}
	if a.traceStop != nil {
		_ = a.traceStop(ctx)
	}
	a.wg.Wait() // drain relay + consumer + grpc loops before closing pools
	if a.relay != nil {
		a.relay.Close()
	}
	if a.store != nil {
		a.store.Close()
	}
	if a.server != nil {
		return a.server.Stop(ctx)
	}
	return nil
}
