// notification-svc — context #13's single egress fabric (R8/ADR-012 channel parity).
package main

import (
	"context"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"gitlab.com/final-year-project3354127/platform-services/internal/config"
	"gitlab.com/final-year-project3354127/platform-services/internal/consumer"
	"gitlab.com/final-year-project3354127/platform-services/internal/httpx"
	"gitlab.com/final-year-project3354127/platform-services/internal/notification"
	"gitlab.com/final-year-project3354127/platform-services/internal/obs"
	"gitlab.com/final-year-project3354127/platform-services/internal/security"
	"gitlab.com/final-year-project3354127/platform-services/internal/store"
)

func main() {
	log := obs.NewLogger()
	cfg := config.Load()
	cfg.ServiceName = "notification-svc"
	if cfg.ConsumerGroup == "platform-svc" {
		cfg.ConsumerGroup = "notification-svc"
	}
	if err := cfg.Validate(); err != nil {
		log.Error("config invalid", "err", err)
		os.Exit(1)
	}
	if cfg.RabbitURL == "" {
		log.Error("config invalid", "err", "DKD_RABBIT_URL is required")
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
	if err := st.MigrateNotification(ctx, now()); err != nil {
		log.Error("migrate", "err", err)
		os.Exit(1)
	}

	metrics := obs.NewMetrics()
	rabbit := notification.NewRabbit(cfg.RabbitURL, log)
	svc := notification.New(st, rabbit, log, metrics, now, cfg.B2CURL)
	cons, err := consumer.New(
		consumer.Config{Brokers: cfg.Brokers(), Group: cfg.ConsumerGroup,
			Topics: notification.Topics()},
		log, svc.Handle, svc.Park)
	if err != nil {
		log.Error("build consumer", "err", err)
		os.Exit(1)
	}

	var ready atomic.Bool
	auth := security.New(cfg.JWTIssuer, nil)
	apiH := notification.NewAPI(svc)
	server := httpx.New(cfg.ServiceName, cfg.HTTPPort, cfg.MetricsPort, log, metrics, auth,
		ready.Load, apiH.Register)
	if err := server.Start(); err != nil {
		log.Error("http listeners", "err", err)
		os.Exit(1)
	}

	var wg sync.WaitGroup
	wg.Add(2)
	go func() { defer wg.Done(); cons.Run(ctx) }()
	go func() { defer wg.Done(); rabbit.RunDispatcher(ctx, svc.Dispatch, svc.MarkFailed) }()
	ready.Store(true)
	log.Info("notification-svc started (R8 SMS+USSD parity, dev-sink adapter)")

	<-ctx.Done()
	ready.Store(false)
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	_ = server.Stop(shutdownCtx)
	cons.Close()
	rabbit.Close()
	wg.Wait()
	st.Close()
	log.Info("stopped cleanly")
}
