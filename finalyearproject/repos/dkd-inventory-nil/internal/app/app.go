// Package app wires inventory-svc: dkd_inventory Postgres, the custody projection consumer,
// and the G2 REST seam. Inventory owns NO spine topics (frozen registry) — no outbox relay.
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

	"gitlab.com/final-year-project3354127/inventory-svc/internal/api"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/config"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/httpx"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/obs"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/projection"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/reservationohs"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/reservationohs/pb"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/security"
	"gitlab.com/final-year-project3354127/inventory-svc/internal/store"
)

type App struct {
	cfg     config.Config
	log     *slog.Logger
	metrics *obs.Metrics
	server  *httpx.Server
	store     *store.Store
	cons      *consumer.Consumer
	grpcSrv   *grpc.Server
	traceStop func(context.Context) error
	wg        sync.WaitGroup
	ready     atomic.Bool
}

func New(cfg config.Config, log *slog.Logger) *App {
	return &App{cfg: cfg, log: log, metrics: obs.NewMetrics()}
}

func (a *App) isReady() bool { return a.ready.Load() }

func (a *App) Start(ctx context.Context) error {
	// INV-04: install the real OTel tracer provider (record-only when DKD_OTLP_ENDPOINT is unset).
	_, a.traceStop = obs.InitTracer(ctx, a.cfg.ServiceName, a.cfg.OtlpEndpoint)

	st, err := store.Open(ctx, a.cfg.DSN())
	if err != nil {
		return fmt.Errorf("connect db: %w", err)
	}
	a.store = st
	if err := st.Migrate(ctx); err != nil {
		return fmt.Errorf("migrate: %w", err)
	}

	apiH := api.New(st, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() })
	auth := security.New(a.cfg.JWTIssuer, nil)
	a.server = httpx.New(a.cfg.ServiceName, a.cfg.HTTPPort, a.cfg.MetricsPort,
		a.log, a.metrics, auth, a.isReady, apiH.Register)
	if err := a.server.Start(); err != nil {
		return fmt.Errorf("http listeners: %w", err)
	}

	// B2B-F2 / EF-API-1: expose the G2 reserve/transition writes over gRPC (internal OHS plane).
	lis, err := net.Listen("tcp", fmt.Sprintf("0.0.0.0:%d", a.cfg.GrpcPort))
	if err != nil {
		return fmt.Errorf("grpc listen: %w", err)
	}
	a.grpcSrv = grpc.NewServer()
	pb.RegisterInventoryReservationOhsServer(a.grpcSrv, reservationohs.New(st, func() int64 { return time.Now().UnixMilli() }))
	go func() {
		if err := a.grpcSrv.Serve(lis); err != nil {
			a.log.Warn("grpc server stopped", "err", err.Error())
		}
	}()
	a.log.Info("inventory reservation gRPC OHS listening", "port", a.cfg.GrpcPort)

	proj := projection.New(st, a.metrics, a.log, func() int64 { return time.Now().UnixMilli() })
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
	a.log.Info("inventory-svc started (R1 read-side + G2 strong-local seam)", "db", a.cfg.DBName)
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
	if a.store != nil {
		a.store.Close()
	}
	if a.grpcSrv != nil {
		a.grpcSrv.GracefulStop()
	}
	if a.server != nil {
		return a.server.Stop(ctx)
	}
	return nil
}
