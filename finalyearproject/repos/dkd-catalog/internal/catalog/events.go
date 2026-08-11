package catalog

import (
	"encoding/json"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

// Event is an outbox-ready domain fact for the Kafka spine (R6): frozen topic name, GPID ordering
// key, UUIDv7 event_id (downstream inbox dedup), canonical-IDs-only JSON payload (never PII).
// Formal payload schemas are NEEDS-INFO in schema-registry; shapes below follow the DM prose.
type Event struct {
	Topic        string
	Key          string
	EventID      string
	OccurredAtMs int64
	Payload      []byte
}

func mustJSON(v any) []byte {
	b, err := json.Marshal(v)
	if err != nil {
		// all payload types below are marshal-safe; a failure is a programming error
		panic("catalog: event payload marshal: " + err.Error())
	}
	return b
}

func newEvent(topic string, p *Product, at int64, payload any) Event {
	return Event{
		Topic:        topic,
		Key:          string(p.GPID),
		EventID:      uuidv7New(),
		OccurredAtMs: at,
		Payload:      mustJSON(payload),
	}
}

func BuildProductCreated(p *Product) Event {
	return newEvent(dkd.TopicCatalogProductProductCreatedV1, p, p.CreatedAtMs, map[string]any{
		"gpid":         string(p.GPID),
		"categoryPath": p.CategoryPath,
		"namesBn":      p.NamesBn,
		"namesEn":      p.NamesEn,
		"baseUnit":     p.BaseUnit,
		"createdBy":    p.CreatedBy,
		"createdAt":    p.CreatedAtMs,
	})
}

func BuildProductPublished(p *Product, by string, at int64) Event {
	return newEvent(dkd.TopicCatalogProductProductPublishedV1, p, at, map[string]any{
		"gpid":        string(p.GPID),
		"publishedAt": at,
		"publishedBy": by,
	})
}

func BuildProductMasterDataUpdated(p *Product, fields []string, by string, at int64) Event {
	return newEvent(dkd.TopicCatalogProductProductMasterDataUpdatedV1, p, at, map[string]any{
		"gpid":          string(p.GPID),
		"updatedFields": fields,
		"updatedAt":     at,
		"updatedBy":     by,
	})
}

func BuildProductPriceRuleAdded(p *Product, r PriceRule, by string, at int64) Event {
	return newEvent(dkd.TopicCatalogProductProductPriceRuleAddedV1, p, at, map[string]any{
		"gpid":            string(p.GPID),
		"ruleId":          r.RuleID,
		"tierApplicable":  r.TierApplicable,
		"basePricePoisha": r.BasePricePoisha,
		"validFrom":       r.ValidFromMs,
		"validUntil":      r.ValidUntilMs,
		"addedBy":         by,
		"addedAt":         at,
	})
}

func BuildProductDeprecated(p *Product, successorGpid, reason, by string, at int64) Event {
	return newEvent(dkd.TopicCatalogProductProductDeprecatedV1, p, at, map[string]any{
		"gpid":          string(p.GPID),
		"successorGpid": successorGpid,
		"reason":        reason,
		"deprecatedAt":  at,
		"deprecatedBy":  by,
	})
}
