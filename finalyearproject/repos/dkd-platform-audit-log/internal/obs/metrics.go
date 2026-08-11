package obs

import (
	"fmt"
	"net/http"
	"sync"
)

// Metrics is a minimal, dependency-free Prometheus-text counter registry. Swap for the Prometheus
// client library at the integration point if richer metric types are needed.
type Metrics struct {
	mu       sync.Mutex
	counters map[string]float64
}

func NewMetrics() *Metrics { return &Metrics{counters: map[string]float64{}} }

func (m *Metrics) Inc(name string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.counters[name]++
}

func (m *Metrics) Handler() http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, _ *http.Request) {
		m.mu.Lock()
		defer m.mu.Unlock()
		w.Header().Set("Content-Type", "text/plain; version=0.0.4")
		for name, v := range m.counters {
			fmt.Fprintf(w, "%s %g\n", name, v)
		}
	})
}
