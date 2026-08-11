//go:build integration

// PRV-03: real coverage of the provenance graph projection core — genesis apply + idempotency, the
// out-of-order transfer guard (H3: a stale event must not overwrite newer holder state), and the
// RECALLED terminal. Runs against the Neo4j engine via DKD_NEO4J_* (unique PPIDs isolate on the
// shared instance).
package graph

import (
	"context"
	"fmt"
	"os"
	"testing"
	"time"
)

func testClient(t *testing.T) (*Client, string) {
	t.Helper()
	uri := os.Getenv("DKD_NEO4J_URI")
	pw := os.Getenv("DKD_NEO4J_PASSWORD")
	if uri == "" || pw == "" {
		t.Skip("DKD_NEO4J_URI/PASSWORD not set — integration Neo4j required")
	}
	user := os.Getenv("DKD_NEO4J_USER")
	if user == "" {
		user = "neo4j"
	}
	c, err := New(uri, user, pw)
	if err != nil {
		t.Fatalf("connect: %v", err)
	}
	t.Cleanup(func() { _ = c.Close(context.Background()) })
	if err := c.Ping(context.Background()); err != nil {
		t.Fatalf("ping: %v", err)
	}
	return c, fmt.Sprintf("PP-test-%d", time.Now().UnixNano())
}

func TestApplyInitialized_Idempotent(t *testing.T) {
	c, ppid := testClient(t)
	ctx := context.Background()
	p := map[string]any{"ppid": ppid, "gpid": "GP-x", "holder": "did:dokandar:h1", "holderRole": "PRODUCER",
		"quantity": int64(10), "unit": "kg", "eventHash": "hash-genesis"}
	if err := c.ApplyInitialized(ctx, p, 1000); err != nil {
		t.Fatalf("apply genesis: %v", err)
	}
	node, err := c.GetPassport(ctx, ppid)
	if err != nil || node == nil {
		t.Fatalf("get: %v node=%v", err, node)
	}
	if node["status"] != "ACTIVE" || node["holder"] != "did:dokandar:h1" {
		t.Fatalf("genesis node wrong: %+v", node)
	}
	// idempotent re-apply — no duplicate, no state change
	if err := c.ApplyInitialized(ctx, p, 1000); err != nil {
		t.Fatalf("re-apply: %v", err)
	}
	node2, _ := c.GetPassport(ctx, ppid)
	if node2["holder"] != "did:dokandar:h1" || node2["status"] != "ACTIVE" {
		t.Fatalf("idempotent re-apply changed state: %+v", node2)
	}
}

func TestApplyTransferred_OutOfOrderGuard(t *testing.T) {
	c, ppid := testClient(t)
	ctx := context.Background()
	_ = c.ApplyInitialized(ctx, map[string]any{"ppid": ppid, "gpid": "GP-x", "holder": "did:dokandar:h1",
		"holderRole": "PRODUCER", "quantity": int64(10), "unit": "kg", "eventHash": "g"}, 1000)

	// a NEWER transfer (t=2000) moves the holder to h2
	_ = c.ApplyTransferred(ctx, map[string]any{"ppid": ppid, "fromHolder": "did:dokandar:h1",
		"toHolder": "did:dokandar:h2", "toHolderRole": "DISTRIBUTOR", "referenceOrd": "ORD-1", "eventHash": "t2"}, 2000)
	if n, _ := c.GetPassport(ctx, ppid); n["holder"] != "did:dokandar:h2" {
		t.Fatalf("newer transfer must set holder h2: %+v", n)
	}

	// a STALE transfer (t=1500 < 2000) arriving late must NOT overwrite the holder (H3 guard)
	_ = c.ApplyTransferred(ctx, map[string]any{"ppid": ppid, "fromHolder": "did:dokandar:h1",
		"toHolder": "did:dokandar:hSTALE", "toHolderRole": "X", "referenceOrd": "ORD-0", "eventHash": "t1"}, 1500)
	if n, _ := c.GetPassport(ctx, ppid); n["holder"] != "did:dokandar:h2" {
		t.Fatalf("stale out-of-order transfer wrongly overwrote holder: %+v", n)
	}
}

func TestApplyRecalled_Terminal(t *testing.T) {
	c, ppid := testClient(t)
	ctx := context.Background()
	_ = c.ApplyInitialized(ctx, map[string]any{"ppid": ppid, "gpid": "GP-x", "holder": "did:dokandar:h1",
		"holderRole": "PRODUCER", "quantity": int64(10), "unit": "kg", "eventHash": "g"}, 1000)
	if err := c.ApplyRecalled(ctx, []string{ppid}, "RCL-1", "GP-x", "contamination", 3000); err != nil {
		t.Fatalf("recall: %v", err)
	}
	if n, _ := c.GetPassport(ctx, ppid); n["status"] != "RECALLED" {
		t.Fatalf("recall must set RECALLED: %+v", n)
	}
}
