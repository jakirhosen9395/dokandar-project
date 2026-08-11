package main

import (
	"context"
	"os"
	"os/signal"
	"syscall"
	"time"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/app"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/config"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/obs"
)

func main() {
	log := obs.NewLogger()
	cfg := config.Load()
	if err := cfg.Validate(); err != nil {
		log.Error("config invalid", "err", err)
		os.Exit(1)
	}

	application := app.New(cfg, log)

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := application.Start(ctx); err != nil {
		log.Error("startup failed", "err", err)
		os.Exit(1)
	}

	<-ctx.Done()
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := application.Stop(shutdownCtx); err != nil {
		log.Error("graceful shutdown error", "err", err)
		os.Exit(1)
	}
	log.Info("stopped cleanly")
}
