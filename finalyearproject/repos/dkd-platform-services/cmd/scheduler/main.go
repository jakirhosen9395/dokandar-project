// scheduler-svc — context #13's clock authority (DM Scheduler Event Catalog; Saga 3).
package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"gitlab.com/final-year-project3354127/platform-services/internal/config"
	"gitlab.com/final-year-project3354127/platform-services/internal/consumer"
	"gitlab.com/final-year-project3354127/platform-services/internal/httpx"
	"gitlab.com/final-year-project3354127/platform-services/internal/obs"
	"gitlab.com/final-year-project3354127/platform-services/internal/outbox"
	"gitlab.com/final-year-project3354127/platform-services/internal/scheduler"
	"gitlab.com/final-year-project3354127/platform-services/internal/security"
	"gitlab.com/final-year-project3354127/platform-services/internal/store"
)

func main() {
	log := obs.NewLogger()
	cfg := config.Load()
	cfg.ServiceName = "scheduler-svc"
	if cfg.ConsumerGroup == "platform-svc" {
		cfg.ConsumerGroup = "scheduler-svc"
	}
	if err := cfg.Validate(); err != nil {
		log.Error("config invalid", "err", err)
		os.Exit(1)
	}
	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()
	// PLAT-08: install the real OTel tracer provider (record-only when DKD_OTLP_ENDPOINT unset).
	_, traceStop := obs.InitTracer(ctx, cfg.ServiceName, cfg.OtlpEndpoint)
	defer func() { _ = traceStop(ctx) }()

	st, err := store.Open(ctx, cfg.DSN())
	if err != nil {
		log.Error("connect db", "err", err)
		os.Exit(1)
	}
	now := func() int64 { return time.Now().UnixMilli() }
	if err := st.MigrateScheduler(ctx, now()); err != nil {
		log.Error("migrate", "err", err)
		os.Exit(1)
	}

	metrics := obs.NewMetrics()
	var gpids []string
	for _, g := range strings.Split(cfg.NILGpids, ",") {
		if g = strings.TrimSpace(g); g != "" {
			gpids = append(gpids, g)
		}
	}
	sched := scheduler.New(st, log, metrics, now, cfg.EscrowAbandonMs, gpids)

	relay, err := outbox.New(cfg.Brokers(), st, log, metrics)
	if err != nil {
		log.Error("build relay", "err", err)
		os.Exit(1)
	}
	cons, err := consumer.New(
		consumer.Config{Brokers: cfg.Brokers(), Group: cfg.ConsumerGroup, Topics: scheduler.Topics()},
		log, sched.Handle, sched.Park)
	if err != nil {
		log.Error("build consumer", "err", err)
		os.Exit(1)
	}

	var ready atomic.Bool
	auth := security.New(cfg.JWTIssuer, nil)
	server := httpx.New(cfg.ServiceName, cfg.HTTPPort, cfg.MetricsPort, log, metrics, auth,
		ready.Load, func(*http.ServeMux) {})
	if err := server.Start(); err != nil {
		log.Error("http listeners", "err", err)
		os.Exit(1)
	}

	var wg sync.WaitGroup
	wg.Add(3)
	go func() { defer wg.Done(); relay.Run(ctx) }()
	go func() { defer wg.Done(); cons.Run(ctx) }()
	go func() {
		defer wg.Done()
		sched.RunTicks(ctx, time.Duration(cfg.TickMs)*time.Millisecond,
			time.Duration(cfg.NILTickMs)*time.Millisecond)
	}()
	ready.Store(true)
	log.Info("scheduler-svc started", "ttlMs", cfg.EscrowAbandonMs, "nilGpids", len(gpids))

	<-ctx.Done()
	ready.Store(false)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = server.Stop(shutdownCtx)
	cons.Close()
	relay.Close()
	wg.Wait()
	st.Close()
	log.Info("stopped cleanly")
}
