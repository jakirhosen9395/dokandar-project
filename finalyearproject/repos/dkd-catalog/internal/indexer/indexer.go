// Package indexer maintains the OpenSearch catalog read model (catalog-search-indexer worker).
// It consumes catalog's OWN catalog.product.* spine topics (outbox-published truth) and upserts
// documents keyed by GPID — replays are idempotent, so no inbox table is needed. The frozen
// RabbitMQ queue catalog.search-index remains a declared extension point (BUILD LOG D10).
package indexer

import (
	"context"
	"encoding/json"
	"errors"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/catalog-svc/internal/catalog"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/consumer"
	"gitlab.com/final-year-project3354127/catalog-svc/internal/store"
)

const (
	MetricIndexed = "catalog_search_docs_indexed_total"
	MetricSkipped = "catalog_search_events_skipped_total"
	MetricParked  = "catalog_search_events_parked_total"
)

type Store interface {
	GetProduct(ctx context.Context, gpid string) (*catalog.Product, error)
}

type Search interface {
	IndexProduct(ctx context.Context, gpid string, doc map[string]any) error
}

type Metrics interface{ Inc(name string) }

type Indexer struct {
	st  Store
	se  Search
	m   Metrics
	log *slog.Logger
}

func New(st Store, se Search, m Metrics, log *slog.Logger) *Indexer {
	return &Indexer{st: st, se: se, m: m, log: log}
}

// Topics is the index-feed: lifecycle + master-data + price events on the product aggregate.
func Topics() []string {
	return []string{
		dkd.TopicCatalogProductProductPublishedV1,
		dkd.TopicCatalogProductProductMasterDataUpdatedV1,
		dkd.TopicCatalogProductProductPriceRuleAddedV1,
		dkd.TopicCatalogProductProductDeprecatedV1,
	}
}

// Handle re-reads the aggregate (intra-context read — same bounded context) and upserts the doc.
// DEPRECATED products stay in the index with their status so searchers can filter.
func (ix *Indexer) Handle(ctx context.Context, ev consumer.RawEvent) error {
	var body struct {
		GPID string `json:"gpid"`
	}
	if err := json.Unmarshal(ev.Value, &body); err != nil || body.GPID == "" {
		ix.m.Inc(MetricSkipped)
		ix.log.Warn("index event without parsable gpid; skipped", "topic", ev.Topic, "event_id", ev.EventID)
		return nil
	}
	p, err := ix.st.GetProduct(ctx, body.GPID)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			ix.m.Inc(MetricSkipped)
			ix.log.Warn("indexed gpid not in store; skipped", "gpid", body.GPID)
			return nil
		}
		return err
	}
	doc := map[string]any{
		"gpid":         string(p.GPID),
		"namesBn":      p.NamesBn,
		"namesEn":      p.NamesEn,
		"categoryPath": p.CategoryPath,
		"baseUnit":     p.BaseUnit,
		"status":       string(p.Status),
		"updatedAt":    p.UpdatedAtMs,
	}
	if err := ix.se.IndexProduct(ctx, string(p.GPID), doc); err != nil {
		return err
	}
	ix.m.Inc(MetricIndexed)
	return nil
}

// Park acknowledges after logging: the index is rebuildable by replaying the topics.
func (ix *Indexer) Park(ev consumer.RawEvent, cause error) bool {
	ix.m.Inc(MetricParked)
	ix.log.Error("search-index event parked (index rebuildable by replay)",
		"topic", ev.Topic, "event_id", ev.EventID, "err", cause)
	return true
}
