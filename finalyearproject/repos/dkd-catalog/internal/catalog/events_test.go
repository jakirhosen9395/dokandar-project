package catalog

import (
	"encoding/json"
	"testing"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

// Topics must be the frozen Published-Language names (SDK constants), key = GPID (ordering key),
// payloads carry canonical IDs only (DIDs, GPID) — never PII.
func TestBuildEventsUseFrozenTopicsAndGPIDKey(t *testing.T) {
	p := mustProduct(t)
	evs := []Event{
		BuildProductCreated(p),
		BuildProductPublished(p, testDID, nowMs),
		BuildProductMasterDataUpdated(p, []string{"namesEn"}, testDID, nowMs),
		BuildProductPriceRuleAdded(p, PriceRule{RuleID: "r1", TierApplicable: "ALL", BasePricePoisha: 5, ValidFromMs: 1}, testDID, nowMs),
		BuildProductDeprecated(p, "", "superseded", testDID, nowMs),
	}
	wantTopics := []string{
		dkd.TopicCatalogProductProductCreatedV1,
		dkd.TopicCatalogProductProductPublishedV1,
		dkd.TopicCatalogProductProductMasterDataUpdatedV1,
		dkd.TopicCatalogProductProductPriceRuleAddedV1,
		dkd.TopicCatalogProductProductDeprecatedV1,
	}
	for i, ev := range evs {
		if ev.Topic != wantTopics[i] {
			t.Fatalf("event %d topic %s want %s", i, ev.Topic, wantTopics[i])
		}
		if ev.Key != string(p.GPID) {
			t.Fatalf("ordering key must be GPID, got %s", ev.Key)
		}
		if ev.EventID == "" {
			t.Fatal("event_id required (consumer inbox dedup key)")
		}
		var m map[string]any
		if err := json.Unmarshal(ev.Payload, &m); err != nil {
			t.Fatalf("payload not json: %v", err)
		}
		if m["gpid"] != string(p.GPID) {
			t.Fatal("payload must carry the gpid")
		}
	}
}

func TestProductCreatedPayloadShape(t *testing.T) {
	p := mustProduct(t)
	ev := BuildProductCreated(p)
	var m map[string]any
	_ = json.Unmarshal(ev.Payload, &m)
	for _, k := range []string{"gpid", "categoryPath", "namesBn", "baseUnit", "createdBy", "createdAt"} {
		if _, ok := m[k]; !ok {
			t.Fatalf("ProductCreated payload missing %q (DM shape)", k)
		}
	}
	if m["createdBy"] != testDID {
		t.Fatal("createdBy must be the canonical DID")
	}
	if _, isNum := m["createdAt"].(float64); !isNum {
		t.Fatal("createdAt must be numeric unix-ms")
	}
}

func TestPublishedAndDeprecatedPayloadShapes(t *testing.T) {
	p := mustProduct(t)
	pub := BuildProductPublished(p, testDID, nowMs)
	var m map[string]any
	_ = json.Unmarshal(pub.Payload, &m)
	for _, k := range []string{"gpid", "publishedAt", "publishedBy"} {
		if _, ok := m[k]; !ok {
			t.Fatalf("ProductPublished missing %q", k)
		}
	}
	dep := BuildProductDeprecated(p, "GP-rice-0198c0de-0000-7000-8000-000000000009", "superseded", testDID, nowMs)
	m = map[string]any{}
	_ = json.Unmarshal(dep.Payload, &m)
	for _, k := range []string{"gpid", "successorGpid", "reason", "deprecatedAt", "deprecatedBy"} {
		if _, ok := m[k]; !ok {
			t.Fatalf("ProductDeprecated missing %q", k)
		}
	}
}

func TestEventIDsAreUniqueUUIDv7(t *testing.T) {
	p := mustProduct(t)
	a, b := BuildProductCreated(p), BuildProductCreated(p)
	if a.EventID == b.EventID {
		t.Fatal("event ids must be unique")
	}
	if len(a.EventID) != 36 || a.EventID[14] != '7' {
		t.Fatalf("event_id must be uuidv7: %s", a.EventID)
	}
}
