// Package graph is the Neo4j projection of custody truth (DM vocabulary: PassportNode nodes,
// TRANSFER/SPLIT_FROM/MERGE_INTO/RECALL relationships). Applies are idempotent AND
// out-of-order-safe: node writes are guarded by the event's OWN timestamp, creation uses
// ON CREATE, and terminal statuses (RECALLED) are never resurrected (review C1/H2/H3 fixes).
package graph

import (
	"context"
	"fmt"

	"github.com/neo4j/neo4j-go-driver/v5/neo4j"
)

const MaxRecallDepth = 10 // DM MAX_RECALL_DEPTH

type Client struct {
	drv neo4j.DriverWithContext
}

func New(uri, user, password string) (*Client, error) {
	drv, err := neo4j.NewDriverWithContext(uri, neo4j.BasicAuth(user, password, ""))
	if err != nil {
		return nil, fmt.Errorf("graph: driver: %w", err)
	}
	return &Client{drv: drv}, nil
}

func (c *Client) Ping(ctx context.Context) error { return c.drv.VerifyConnectivity(ctx) }

// Close surfaces driver shutdown errors to the caller (review L2).
func (c *Client) Close(ctx context.Context) error { return c.drv.Close(ctx) }

func (c *Client) write(ctx context.Context, cypher string, params map[string]any) error {
	sess := c.drv.NewSession(ctx, neo4j.SessionConfig{AccessMode: neo4j.AccessModeWrite})
	defer sess.Close(ctx)
	_, err := sess.ExecuteWrite(ctx, func(tx neo4j.ManagedTransaction) (any, error) {
		res, err := tx.Run(ctx, cypher, params)
		if err != nil {
			return nil, err
		}
		return res.Consume(ctx) // surface server-side stream errors (review H1)
	})
	if err != nil {
		return fmt.Errorf("graph: write: %w", err)
	}
	return nil
}

func (c *Client) read(ctx context.Context, cypher string, params map[string]any) ([]map[string]any, error) {
	sess := c.drv.NewSession(ctx, neo4j.SessionConfig{AccessMode: neo4j.AccessModeRead})
	defer sess.Close(ctx)
	out, err := sess.ExecuteRead(ctx, func(tx neo4j.ManagedTransaction) (any, error) {
		res, err := tx.Run(ctx, cypher, params)
		if err != nil {
			return nil, err
		}
		var rows []map[string]any
		for res.Next(ctx) {
			rows = append(rows, res.Record().AsMap())
		}
		return rows, res.Err()
	})
	if err != nil {
		return nil, fmt.Errorf("graph: read: %w", err)
	}
	rows, _ := out.([]map[string]any)
	return rows, nil
}

func (c *Client) touchWatermark(ctx context.Context, atMs int64) error {
	return c.write(ctx, `MERGE (w:Watermark {id:'custody'})
		SET w.lastAppliedMs = CASE WHEN w.lastAppliedMs IS NULL OR w.lastAppliedMs < $at
			THEN $at ELSE w.lastAppliedMs END`, map[string]any{"at": atMs})
}

func (c *Client) Watermark(ctx context.Context) (int64, error) {
	rows, err := c.read(ctx, `MATCH (w:Watermark {id:'custody'}) RETURN w.lastAppliedMs AS at`, nil)
	if err != nil || len(rows) == 0 {
		return 0, err
	}
	at, _ := rows[0]["at"].(int64)
	return at, nil
}

// ApplyInitialized creates the genesis node; a LATE init after split/merge/recall must never
// resurrect status or overwrite richer state — ON CREATE only, blanks filled on match (C1).
func (c *Client) ApplyInitialized(ctx context.Context, p map[string]any, atMs int64) error {
	if err := c.write(ctx, `MERGE (n:PassportNode {ppid:$ppid})
		ON CREATE SET n.gpid=$gpid, n.holder=$holder, n.holderRole=$holderRole,
			n.quantity=$quantity, n.unit=$unit, n.status='ACTIVE', n.timestamp=$at, n.eventHash=$eventHash
		ON MATCH SET n.gpid=coalesce(n.gpid,$gpid), n.quantity=coalesce(n.quantity,$quantity),
			n.unit=coalesce(n.unit,$unit), n.holder=coalesce(n.holder,$holder),
			n.holderRole=coalesce(n.holderRole,$holderRole)`,
		map[string]any{"ppid": p["ppid"], "gpid": p["gpid"], "holder": p["holder"],
			"holderRole": p["holderRole"], "quantity": p["quantity"], "unit": p["unit"],
			"at": atMs, "eventHash": p["eventHash"]}); err != nil {
		return err
	}
	return c.touchWatermark(ctx, atMs)
}

// ApplyTransferred guards node properties on the EVENT timestamp so out-of-order transfers
// never leave a stale holder (H3); the TRANSFER self-edge stays keyed by eventHash.
func (c *Client) ApplyTransferred(ctx context.Context, p map[string]any, atMs int64) error {
	if err := c.write(ctx, `MERGE (n:PassportNode {ppid:$ppid})
		WITH n, (n.timestamp IS NULL OR n.timestamp < $at) AS newer
		SET n.holder    = CASE WHEN newer THEN $toHolder     ELSE n.holder    END,
		    n.holderRole= CASE WHEN newer THEN $toHolderRole ELSE n.holderRole END,
		    n.eventHash = CASE WHEN newer THEN $eventHash    ELSE n.eventHash END,
		    n.timestamp = CASE WHEN newer THEN $at           ELSE n.timestamp END
		MERGE (n)-[t:TRANSFER {eventHash:$eventHash}]->(n)
		SET t.fromHolder=$fromHolder, t.toHolder=$toHolder, t.referenceId=$referenceId, t.timestamp=$at`,
		map[string]any{"ppid": p["ppid"], "fromHolder": p["fromHolder"], "toHolder": p["toHolder"],
			"toHolderRole": p["toHolderRole"], "referenceId": p["referenceOrd"],
			"at": atMs, "eventHash": p["eventHash"]}); err != nil {
		return err
	}
	return c.touchWatermark(ctx, atMs)
}

type ChildAlloc struct {
	PPID     string
	Holder   string
	Role     string
	Quantity int64
}

// ApplySplit: single UNWIND round trip (M1); terminal RECALLED is never overwritten (H2).
func (c *Client) ApplySplit(ctx context.Context, parentPpid, gpid, unit, eventHash string, children []ChildAlloc, atMs int64) error {
	items := make([]map[string]any, 0, len(children))
	for _, ch := range children {
		items = append(items, map[string]any{"ppid": ch.PPID, "holder": ch.Holder, "role": ch.Role, "qty": ch.Quantity})
	}
	if err := c.write(ctx, `MERGE (p:PassportNode {ppid:$ppid})
		SET p.status = CASE WHEN p.status = 'RECALLED' THEN 'RECALLED' ELSE 'SPLIT' END,
		    p.timestamp = CASE WHEN p.timestamp IS NULL OR p.timestamp < $at THEN $at ELSE p.timestamp END
		WITH p UNWIND $items AS ch
		MERGE (c:PassportNode {ppid:ch.ppid})
		ON CREATE SET c.gpid=$gpid, c.holder=ch.holder, c.holderRole=ch.role, c.quantity=ch.qty,
			c.unit=$unit, c.status='ACTIVE', c.timestamp=$at, c.eventHash=$eventHash
		MERGE (c)-[e:SPLIT_FROM {eventHash:$eventHash}]->(p) SET e.timestamp=$at`,
		map[string]any{"ppid": parentPpid, "gpid": gpid, "unit": unit, "items": items,
			"at": atMs, "eventHash": eventHash}); err != nil {
		return err
	}
	return c.touchWatermark(ctx, atMs)
}

// ApplyMerged: single UNWIND round trip (M1); RECALLED preserved (H2); eventHash on new node (L1).
func (c *Client) ApplyMerged(ctx context.Context, sourcePpids []string, newPpid, gpid, toHolder, toRole, unit, eventHash string, total, atMs int64) error {
	if err := c.write(ctx, `MERGE (n:PassportNode {ppid:$ppid})
		ON CREATE SET n.gpid=$gpid, n.holder=$holder, n.holderRole=$role, n.quantity=$qty,
			n.unit=$unit, n.status='ACTIVE', n.timestamp=$at, n.eventHash=$eventHash
		WITH n UNWIND $sources AS src
		MERGE (s:PassportNode {ppid:src})
		SET s.status = CASE WHEN s.status = 'RECALLED' THEN 'RECALLED' ELSE 'MERGED' END,
		    s.timestamp = CASE WHEN s.timestamp IS NULL OR s.timestamp < $at THEN $at ELSE s.timestamp END
		MERGE (s)-[e:MERGE_INTO {eventHash:$eventHash}]->(n) SET e.timestamp=$at`,
		map[string]any{"ppid": newPpid, "gpid": gpid, "holder": toHolder, "role": toRole,
			"qty": total, "unit": unit, "sources": sourcePpids, "at": atMs, "eventHash": eventHash}); err != nil {
		return err
	}
	return c.touchWatermark(ctx, atMs)
}

// ApplyRecalled: RECALLED is the strongest terminal — unconditional is correct.
func (c *Client) ApplyRecalled(ctx context.Context, ppids []string, recallID, gpid, reason string, atMs int64) error {
	if err := c.write(ctx, `UNWIND $ppids AS pp
		MERGE (n:PassportNode {ppid:pp}) SET n.status='RECALLED',
			n.timestamp = CASE WHEN n.timestamp IS NULL OR n.timestamp < $at THEN $at ELSE n.timestamp END
		MERGE (n)-[r:RECALL {recallId:$recallId}]->(n) SET r.timestamp=$at`,
		map[string]any{"ppids": ppids, "recallId": recallID, "at": atMs}); err != nil {
		return err
	}
	if err := c.write(ctx, `MERGE (rc:RecallCase {recallId:$recallId})
		SET rc.gpid=$gpid, rc.reason=$reason, rc.status='SCOPED', rc.rootPpids=$ppids, rc.computedAt=$at`,
		map[string]any{"recallId": recallID, "gpid": gpid, "reason": reason, "ppids": ppids, "at": atMs}); err != nil {
		return err
	}
	return c.touchWatermark(ctx, atMs)
}

func (c *Client) ApplySigned(ctx context.Context, ppid, agentDid string, atMs int64) error {
	if err := c.write(ctx, `MERGE (n:PassportNode {ppid:$ppid})
		SET n.lastSignedBy=$agent,
		    n.lastSignedAt = CASE WHEN n.lastSignedAt IS NULL OR n.lastSignedAt < $at THEN $at ELSE n.lastSignedAt END`,
		map[string]any{"ppid": ppid, "agent": agentDid, "at": atMs}); err != nil {
		return err
	}
	return c.touchWatermark(ctx, atMs)
}

func (c *Client) GetPassport(ctx context.Context, ppid string) (map[string]any, error) {
	rows, err := c.read(ctx, `MATCH (n:PassportNode {ppid:$ppid}) RETURN properties(n) AS node`,
		map[string]any{"ppid": ppid})
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	node, _ := rows[0]["node"].(map[string]any)
	return node, nil
}

// Lineage returns the undirected split/merge family of a PPID, depth-bounded (DM: 10).
func (c *Client) Lineage(ctx context.Context, ppid string) ([]map[string]any, error) {
	rows, err := c.read(ctx, `MATCH (n:PassportNode {ppid:$ppid})
		OPTIONAL MATCH (n)-[:SPLIT_FROM|MERGE_INTO*1..10]-(rel:PassportNode)
		WITH collect(DISTINCT properties(rel)) AS related, properties(n) AS self
		RETURN self, related`, map[string]any{"ppid": ppid})
	if err != nil || len(rows) == 0 {
		return nil, err
	}
	out := []map[string]any{}
	if self, ok := rows[0]["self"].(map[string]any); ok {
		out = append(out, self)
	}
	if related, ok := rows[0]["related"].([]any); ok {
		for _, r := range related {
			if m, ok := r.(map[string]any); ok {
				out = append(out, m)
			}
		}
	}
	return out, nil
}

type RecallScope struct {
	RecallID         string   `json:"recallId"`
	Status           string   `json:"status"`
	Reason           string   `json:"reason"`
	RootPpids        []string `json:"rootPpids"`
	AffectedPpids    []string `json:"affectedPpids"`
	EstimatedHolders []string `json:"estimatedHolderDids"`
	TraversalDepth   int      `json:"traversalDepth"`
	ComputedAt       int64    `json:"computedAt"`
}

// Scope computes the DM Recall Impact by UNDIRECTED lineage traversal from the recalled roots —
// a deliberate over-approximation biased toward recall breadth (G11; BUILD LOG note).
func (c *Client) Scope(ctx context.Context, recallID string, atMs int64) (*RecallScope, error) {
	rows, err := c.read(ctx, `MATCH (rc:RecallCase {recallId:$recallId})
		UNWIND rc.rootPpids AS rp
		MATCH (root:PassportNode {ppid:rp})
		OPTIONAL MATCH (root)-[:SPLIT_FROM|MERGE_INTO*0..10]-(d:PassportNode)
		WITH rc, collect(DISTINCT d.ppid)+collect(DISTINCT root.ppid) AS pp,
			 collect(DISTINCT d.holder)+collect(DISTINCT root.holder) AS hh
		RETURN properties(rc) AS rc, pp, hh`, map[string]any{"recallId": recallID})
	if err != nil {
		return nil, err
	}
	if len(rows) == 0 {
		return nil, nil
	}
	rc, _ := rows[0]["rc"].(map[string]any)
	scope := &RecallScope{RecallID: recallID, TraversalDepth: MaxRecallDepth, ComputedAt: atMs}
	if s, ok := rc["status"].(string); ok {
		scope.Status = s
	}
	if s, ok := rc["reason"].(string); ok {
		scope.Reason = s
	}
	if roots, ok := rc["rootPpids"].([]any); ok {
		for _, r := range roots {
			if s, ok := r.(string); ok {
				scope.RootPpids = append(scope.RootPpids, s)
			}
		}
	}
	seen := map[string]bool{}
	if pp, ok := rows[0]["pp"].([]any); ok {
		for _, p := range pp {
			if s, ok := p.(string); ok && s != "" && !seen[s] {
				seen[s] = true
				scope.AffectedPpids = append(scope.AffectedPpids, s)
			}
		}
	}
	seenH := map[string]bool{}
	if hh, ok := rows[0]["hh"].([]any); ok {
		for _, h := range hh {
			if s, ok := h.(string); ok && s != "" && !seenH[s] {
				seenH[s] = true
				scope.EstimatedHolders = append(scope.EstimatedHolders, s)
			}
		}
	}
	return scope, nil
}
