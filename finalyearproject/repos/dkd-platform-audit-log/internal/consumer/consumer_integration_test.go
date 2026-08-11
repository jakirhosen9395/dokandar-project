//go:build integration

package consumer

import (
	"context"
	"os"
	"strings"
	"sync"
	"testing"
	"time"

	"github.com/twmb/franz-go/pkg/kadm"
	"github.com/twmb/franz-go/pkg/kgo"

	"gitlab.com/final-year-project3354127/audit-log-svc/internal/audit"
)

// NOTE: producing/admin here is done by the TEST HARNESS acting as a topic owner. The service under
// test (this package's Consumer) never produces and never creates topics (R6 + CORRECTION 2).

func testBrokers(t *testing.T) []string {
	b := os.Getenv("DKD_TEST_KAFKA_BROKERS")
	if b == "" {
		b = os.Getenv("DKD_KAFKA_BROKERS")
	}
	if b == "" {
		t.Skip("no DKD_TEST_KAFKA_BROKERS/DKD_KAFKA_BROKERS set; consumer integration test skipped")
	}
	var out []string
	for _, s := range strings.Split(b, ",") {
		if s = strings.TrimSpace(s); s != "" {
			out = append(out, s)
		}
	}
	return out
}

func sessionName(prefix string) string {
	return prefix + "." + time.Now().UTC().Format("150405.000000000")
}

func TestConsumerRoundTrip(t *testing.T) {
	brokers := testBrokers(t)
	topic := sessionName("platform.audit-it.RoundTrip.v1")
	group := sessionName("audit-log-svc-it")

	admCl, err := kgo.NewClient(kgo.SeedBrokers(brokers...))
	if err != nil {
		t.Fatalf("admin client: %v", err)
	}
	defer admCl.Close()
	adm := kadm.NewClient(admCl)
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	if _, err := adm.CreateTopics(ctx, 1, 1, nil, topic); err != nil {
		t.Fatalf("create topic (owner): %v", err)
	}
	defer func() { _, _ = adm.DeleteTopics(context.Background(), topic) }() // cleanup session topic

	// produce one record with an event_id header
	rec := &kgo.Record{Topic: topic, Key: []byte("PPID-1"),
		Value:   []byte(`{"eventId":"rt-1","did":"did:dokandar:x"}`),
		Headers: []kgo.RecordHeader{{Key: "event_id", Value: []byte("rt-1")}}}
	if err := admCl.ProduceSync(ctx, rec).FirstErr(); err != nil {
		t.Fatalf("produce: %v", err)
	}

	var mu sync.Mutex
	got := map[string]audit.RawEvent{}
	handler := func(_ context.Context, e audit.RawEvent) error {
		mu.Lock()
		got[e.EventID] = e
		mu.Unlock()
		return nil
	}
	c, err := New(Config{Brokers: brokers, Group: group, Topics: []string{topic}}, testLog(), handler, noopPark)
	if err != nil {
		t.Fatalf("new consumer: %v", err)
	}
	defer c.Close()
	if err := c.Ping(ctx); err != nil {
		t.Fatalf("ping: %v", err)
	}
	runCtx, runCancel := context.WithCancel(ctx)
	go c.Run(runCtx)

	deadline := time.Now().Add(20 * time.Second)
	for time.Now().Before(deadline) {
		mu.Lock()
		_, ok := got["rt-1"]
		mu.Unlock()
		if ok {
			break
		}
		time.Sleep(250 * time.Millisecond)
	}
	runCancel()

	mu.Lock()
	e, ok := got["rt-1"]
	mu.Unlock()
	if !ok {
		t.Fatal("did not receive produced record within deadline")
	}
	if e.Topic != topic || e.Key != "PPID-1" {
		t.Fatalf("record mismatch: %+v", e)
	}
}

// TestConsumerDoesNotCreateTopic proves CORRECTION 2 at the Go level: subscribing to a
// not-yet-existing topic must NOT create it.
func TestConsumerDoesNotCreateTopic(t *testing.T) {
	brokers := testBrokers(t)
	absent := sessionName("platform.audit-it.NeverCreated.v1")

	admCl, err := kgo.NewClient(kgo.SeedBrokers(brokers...))
	if err != nil {
		t.Fatalf("admin client: %v", err)
	}
	defer admCl.Close()
	adm := kadm.NewClient(admCl)
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()

	c, err := New(Config{Brokers: brokers, Group: sessionName("audit-nc-it"), Topics: []string{absent}}, testLog(), noopHandler, noopPark)
	if err != nil {
		t.Fatalf("new consumer: %v", err)
	}
	defer c.Close()
	// let the client refresh metadata / attempt to consume the absent topic
	runCtx, runCancel := context.WithTimeout(ctx, 6*time.Second)
	c.Run(runCtx) // returns when runCtx expires
	runCancel()

	td, err := adm.ListTopics(ctx)
	if err != nil {
		t.Fatalf("list topics: %v", err)
	}
	if td.Has(absent) {
		t.Fatalf("consumer must not create topic %q (R6 / CORRECTION 2)", absent)
	}
}
