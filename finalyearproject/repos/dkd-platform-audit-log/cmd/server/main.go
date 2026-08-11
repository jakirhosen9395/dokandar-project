package main

import (
	"context"
	"net/http"
	"os"
	"os/signal"
	"syscall"
	"time"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/app"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/config"
	"gitlab.com/final-year-project3354127/audit-log-svc/internal/obs"
)

func main() {
	// AUD-03: distroless-safe self-healthcheck — `/server -health` dials /health and exits 0/1,
	// so the Dockerfile HEALTHCHECK works without a shell/curl in the image.
	if len(os.Args) > 1 && os.Args[1] == "-health" {
		port := os.Getenv("DKD_HTTP_PORT")
		if port == "" {
			port = "8080"
		}
		resp, err := http.Get("http://127.0.0.1:" + port + "/health")
		if err != nil || resp.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}
	log := obs.NewLogger()
	cfg, err := config.Load()
	if err != nil {
		log.Error("config load failed", "err", err)
		os.Exit(1)
	}
	if err := cfg.Validate(); err != nil { // startup validation
		log.Error("config invalid", "err", err)
		os.Exit(1)
	}

	application, err := app.New(cfg, log) // dependency injection / wiring
	if err != nil {
		log.Error("startup failed", "err", err)
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	if err := application.Start(ctx); err != nil {
		log.Error("run failed", "err", err)
		os.Exit(1)
	}

	<-ctx.Done() // block until signal
	log.Info("shutting down")
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer cancel()
	if err := application.Stop(shutdownCtx); err != nil { // graceful shutdown
		log.Error("graceful shutdown error", "err", err)
		os.Exit(1)
	}
	log.Info("stopped cleanly")
}
