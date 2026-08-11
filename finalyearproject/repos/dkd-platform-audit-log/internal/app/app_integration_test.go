//go:build integration

package app

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"testing"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/config"
)

func freePort(t *testing.T) int {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatalf("free port: %v", err)
	}
	defer l.Close()
	return l.Addr().(*net.TCPAddr).Port
}

// TestAppBootsAndBecomesReady boots the whole App against the real substrate: it connects the DB,
// runs migrations, builds the franz-go consumer over the full spine, pings Kafka, and flips /ready
// true only then. Uses a unique consumer group so it never disturbs the live audit consumer.
func TestAppBootsAndBecomesReady(t *testing.T) {
	dsn := os.Getenv("DKD_TEST_DB_DSN")
	brokers := os.Getenv("DKD_TEST_KAFKA_BROKERS")
	if dsn == "" || brokers == "" {
		t.Skip("needs DKD_TEST_DB_DSN + DKD_TEST_KAFKA_BROKERS")
	}
	port := freePort(t)
	cfg := &config.Config{
		ServiceName:   "audit-log-svc",
		Context:       "platform",
		Env:           "test",
		HTTPPort:      port,
		MetricsPort:   freePort(t),
		LogLevel:      "info",
		KafkaBrokers:  brokers,
		ConsumerGroup: fmt.Sprintf("audit-log-svc-apptest-%d", time.Now().UnixNano()),
		DBDSN:         dsn,
	}
	a, err := New(cfg, slog.New(slog.NewTextHandler(io.Discard, nil)))
	if err != nil {
		t.Fatalf("new: %v", err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	if err := a.Start(ctx); err != nil {
		t.Fatalf("start: %v", err)
	}
	defer func() { _ = a.Stop(context.Background()) }()

	if !a.isReady() {
		t.Fatal("app must be ready after Start (DB + Kafka connected)")
	}
	resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/ready", port))
	if err != nil {
		t.Fatalf("GET /ready: %v", err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		t.Fatalf("/ready -> %d after Start, want 200", resp.StatusCode)
	}
	if n := len(a.topics()); n < 1 {
		t.Fatal("expected a non-empty subscription set")
	}
}
