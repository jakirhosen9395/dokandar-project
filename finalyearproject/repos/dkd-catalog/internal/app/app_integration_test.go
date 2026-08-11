//go:build integration

package app

import (
	"context"
	"fmt"
	"io"
	"net/http"
	"os"
	"strings"
	"testing"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/config"
)

// Boots the WHOLE catalog-svc app against the live substrate (unique consumer group,
// high loopback ports, search disabled) and proves ready flips only after DB+Kafka.
func TestAppBootsAgainstSubstrate(t *testing.T) {
	brokers := os.Getenv("DKD_TEST_KAFKA_BROKERS")
	dsn := os.Getenv("DKD_TEST_DB_DSN")
	if brokers == "" || dsn == "" {
		t.Skip("DKD_TEST_KAFKA_BROKERS / DKD_TEST_DB_DSN not set; app integration test skipped")
	}
	group := fmt.Sprintf("catalog-apptest-%d", time.Now().UnixNano())
	t.Setenv("DKD_KAFKA_BROKERS", brokers)
	t.Setenv("DKD_DB_DSN", dsn)
	t.Setenv("DKD_CONSUMER_GROUP", group)
	t.Setenv("DKD_HTTP_PORT", "18188")
	t.Setenv("DKD_METRICS_PORT", "18189")
	t.Setenv("DKD_SEARCH_URL", "")

	cfg := config.Load()
	if err := cfg.Validate(); err != nil {
		t.Fatal(err)
	}
	a := New(cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if a.isReady() {
		t.Fatal("must not be ready before Start")
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := a.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}
	if !a.isReady() {
		t.Fatal("ready must be true after Start")
	}

	deadline := time.Now().Add(20 * time.Second)
	var body string
	for time.Now().Before(deadline) {
		resp, err := http.Get("http://127.0.0.1:18188/health")
		if err == nil {
			b, _ := io.ReadAll(resp.Body)
			resp.Body.Close()
			if resp.StatusCode == http.StatusOK {
				body = string(b)
				break
			}
		}
		time.Sleep(500 * time.Millisecond)
	}
	if !strings.Contains(body, `"success":true`) {
		t.Fatalf("health body: %q", body)
	}

	// search endpoint must answer 503 problem+json when no backend is configured
	resp, err := http.Get("http://127.0.0.1:18188/v1/catalog/search?q=x")
	if err != nil || resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("search without backend: %v %v", resp, err)
	}
	resp.Body.Close()

	cancel() // stop relay/consumer loops
	stopCtx, stopCancel := context.WithTimeout(context.Background(), 15*time.Second)
	defer stopCancel()
	if err := a.Stop(stopCtx); err != nil {
		t.Fatalf("stop: %v", err)
	}
	if a.isReady() {
		t.Fatal("must not be ready after Stop")
	}
}
