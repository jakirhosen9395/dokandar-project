package httpx

import (
	"context"
	"fmt"
	"io"
	"net"
	"net/http"
	"sync/atomic"
	"testing"
	"time"

	"log/slog"

	"gitlab.com/final-year-project3354127/platform-services/internal/obs"
	"gitlab.com/final-year-project3354127/platform-services/internal/security"
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

func waitUp(t *testing.T, url string) {
	t.Helper()
	for i := 0; i < 100; i++ {
		if resp, err := http.Get(url); err == nil {
			resp.Body.Close()
			return
		}
		time.Sleep(20 * time.Millisecond)
	}
	t.Fatalf("server did not come up at %s", url)
}

// TestServerEndToEnd boots the real Server on ephemeral ports and drives every endpoint through the
// full middleware chain — covering server/middleware/health/openapi plus, transitively, the obs
// (metrics/tracing) and security (JWT Optional) helpers.
func TestServerEndToEnd(t *testing.T) {
	m := obs.NewMetrics()
	auth := security.New("", nil)
	var ready atomic.Bool
	ready.Store(true)
	port, metricsPort := freePort(t), freePort(t)
	s := New("audit-log-svc", port, metricsPort, slog.New(slog.NewTextHandler(io.Discard, nil)), m, auth, ready.Load)
	s.Start()
	defer func() { _ = s.Stop(context.Background()) }()

	base := fmt.Sprintf("http://127.0.0.1:%d", port)
	waitUp(t, base+"/health")

	for _, p := range []string{"/health", "/live", "/ready", "/version", "/docs", "/swagger/v1/swagger.json"} {
		resp, err := http.Get(base + p)
		if err != nil {
			t.Fatalf("GET %s: %v", p, err)
		}
		if resp.StatusCode != http.StatusOK {
			t.Fatalf("GET %s -> %d, want 200", p, resp.StatusCode)
		}
		if resp.Header.Get("X-Content-Type-Options") != "nosniff" {
			t.Fatalf("GET %s missing SecurityHeaders", p)
		}
		resp.Body.Close()
	}

	// A valid-shaped bearer exercises the JWT Optional success path (base64url {"sub":"u"}).
	req, _ := http.NewRequest(http.MethodGet, base+"/version", nil)
	req.Header.Set("Authorization", "Bearer x.eyJzdWIiOiJ1In0.y")
	if resp, err := http.DefaultClient.Do(req); err == nil {
		resp.Body.Close()
	}

	// Metrics endpoint exercises obs.Metrics.Handler.
	if resp, err := http.Get(fmt.Sprintf("http://127.0.0.1:%d/metrics", metricsPort)); err == nil {
		resp.Body.Close()
	}

	// Not-ready branch -> 503.
	ready.Store(false)
	resp, err := http.Get(base + "/ready")
	if err != nil {
		t.Fatalf("GET /ready: %v", err)
	}
	if resp.StatusCode != http.StatusServiceUnavailable {
		t.Fatalf("not-ready /ready -> %d, want 503", resp.StatusCode)
	}
	resp.Body.Close()
}
