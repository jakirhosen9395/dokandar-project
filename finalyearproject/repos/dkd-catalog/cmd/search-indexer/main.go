// catalog-search-indexer — Context #2's OpenSearch read-model worker (second deployable of
// dkd-catalog). Consumes catalog.product.* and upserts the search index (OpenSearch only,
// never observability ES).
package main

import (
	"context"
	"os"
	"os/signal"
	"sync"
	"sync/atomic"
	"syscall"
	"time"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/config"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/httpx"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/indexer"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/obs"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/search"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/security"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/store"
)

func main() {
	log := obs.NewLogger()
	cfg := config.Load()
	if cfg.ServiceName == "catalog-svc" {
		cfg.ServiceName = "catalog-search-indexer"
	}
	if cfg.ConsumerGroup == "catalog-svc" {
		cfg.ConsumerGroup = "catalog-search-indexer"
	}
	if err := cfg.Validate(); err != nil {
		log.Error("config invalid", "err", err)
		os.Exit(1)
	}
	if cfg.SearchURL == "" {
		log.Error("DKD_SEARCH_URL is required for the search indexer (OpenSearch only)")
		os.Exit(1)
	}

	ctx, stop := signal.NotifyContext(context.Background(), syscall.SIGINT, syscall.SIGTERM)
	defer stop()

	st, err := store.Open(ctx, cfg.DSN())
	if err != nil {
		log.Error("connect db failed", "err", err)
		os.Exit(1)
	}
	defer st.Close()

	se := search.New(cfg.SearchURL, cfg.SearchIndex)
	if err := se.Ping(ctx); err != nil {
		log.Error("opensearch ping failed", "err", err)
		os.Exit(1)
	}

	metrics := obs.NewMetrics()
	ix := indexer.New(st, se, metrics, log)
	cons, err := consumer.New(
		consumer.Config{Brokers: cfg.Brokers(), Group: cfg.ConsumerGroup, Topics: indexer.Topics()},
		log, ix.Handle, ix.Park,
	)
	if err != nil {
		log.Error("build consumer failed", "err", err)
		os.Exit(1)
	}
	if err := cons.Ping(ctx); err != nil {
		log.Error("kafka ping failed", "err", err)
		os.Exit(1)
	}

	var ready atomic.Bool
	auth := security.New(cfg.JWTIssuer, nil)
	srv := httpx.New(cfg.ServiceName, cfg.HTTPPort, cfg.MetricsPort, log, metrics, auth, ready.Load)
	if err := srv.Start(); err != nil {
		log.Error("http listeners failed", "err", err)
		os.Exit(1)
	}

	var wg sync.WaitGroup
	wg.Add(1)
	go func() { defer wg.Done(); cons.Run(ctx) }()
	ready.Store(true)
	log.Info("catalog-search-indexer started", "group", cfg.ConsumerGroup, "index", cfg.SearchIndex)

	<-ctx.Done()
	ready.Store(false)
	cons.Close()
	wg.Wait()
	shutdownCtx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	_ = srv.Stop(shutdownCtx)
	log.Info("stopped cleanly")
}
