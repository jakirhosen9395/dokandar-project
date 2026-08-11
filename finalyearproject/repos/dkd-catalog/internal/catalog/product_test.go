package catalog

import (
	"testing"
)

const (
	testDID = "did:dokandar:0198c0de-0000-7000-8000-000000000001"
	nowMs   = int64(1719900000000)
)

func now() int64 { return nowMs }

func mustProduct(t *testing.T) *Product {
	t.Helper()
	p, err := NewProduct(NewProductInput{
		CategoryPath: []string{"agriculture", "rice", "aromatic"},
		CategoryCode: "rice",
		NamesBn:      "চিনিগুঁড়া চাল",
		NamesEn:      "Chinigura rice",
		BaseUnit:     "kg",
		Attributes:   map[string]any{"grade": "A"},
		CreatedBy:    testDID,
	}, now)
	if err != nil {
		t.Fatal(err)
	}
	return p
}

// R8: Bangla-first — namesBn is REQUIRED.
func TestNewProductRequiresBanglaName(t *testing.T) {
	_, err := NewProduct(NewProductInput{
		CategoryPath: []string{"agriculture"}, CategoryCode: "agri",
		NamesBn: "", BaseUnit: "kg", CreatedBy: testDID,
	}, now)
	if err == nil {
		t.Fatal("namesBn must be required (Bangla-first, R8)")
	}
}

func TestNewProductValidation(t *testing.T) {
	base := NewProductInput{CategoryPath: []string{"agriculture"}, CategoryCode: "agri",
		NamesBn: "ধান", BaseUnit: "kg", CreatedBy: testDID}

	noPath := base
	noPath.CategoryPath = nil
	if _, err := NewProduct(noPath, now); err == nil {
		t.Fatal("empty categoryPath must be rejected")
	}
	noUnit := base
	noUnit.BaseUnit = ""
	if _, err := NewProduct(noUnit, now); err == nil {
		t.Fatal("empty baseUnit must be rejected")
	}
	badDID := base
	badDID.CreatedBy = "not-a-did"
	if _, err := NewProduct(badDID, now); err == nil {
		t.Fatal("createdBy must be a did:dokandar DID")
	}
}

func TestNewProductStartsDraftWithValidGPID(t *testing.T) {
	p := mustProduct(t)
	if p.Status != StatusDraft {
		t.Fatalf("new product must be DRAFT, got %s", p.Status)
	}
	if err := ValidateGPID(string(p.GPID)); err != nil {
		t.Fatalf("gpid invalid: %v", err)
	}
	if p.CreatedAtMs != nowMs || p.UpdatedAtMs != nowMs {
		t.Fatal("timestamps must be int64 unix-ms from the injected clock")
	}
}

// Lifecycle: DRAFT -> PUBLISHED -> DEPRECATED only (DM canon; SA extra states are NEEDS-INFO).
func TestLifecycleTransitions(t *testing.T) {
	p := mustProduct(t)
	if err := p.Publish(testDID, now); err != nil {
		t.Fatalf("publish from draft: %v", err)
	}
	if p.Status != StatusPublished {
		t.Fatal("status must be PUBLISHED")
	}
	if err := p.Publish(testDID, now); err == nil {
		t.Fatal("double publish must fail")
	}
	if err := p.Deprecate("", "superseded", testDID, 0, now); err != nil {
		t.Fatalf("deprecate published: %v", err)
	}
	if p.Status != StatusDeprecated {
		t.Fatal("status must be DEPRECATED")
	}
}

func TestDeprecateRequiresPublishedAndZeroActivePassports(t *testing.T) {
	p := mustProduct(t)
	if err := p.Deprecate("", "r", testDID, 0, now); err == nil {
		t.Fatal("deprecate from DRAFT must fail (only PUBLISHED->DEPRECATED)")
	}
	_ = p.Publish(testDID, now)
	// M5 invariant: active custody passports block deprecation
	if err := p.Deprecate("", "r", testDID, 3, now); err == nil {
		t.Fatal("deprecate with active passports must fail (M5)")
	}
}

func TestUpdateMasterDataRejectedWhenDeprecated(t *testing.T) {
	p := mustProduct(t)
	_ = p.Publish(testDID, now)
	_ = p.Deprecate("", "r", testDID, 0, now)
	if _, err := p.UpdateMasterData(map[string]any{"namesEn": "x"}, testDID, now); err == nil {
		t.Fatal("master-data update on DEPRECATED must fail")
	}
}

func TestUpdateMasterDataChangesOnlyKnownFields(t *testing.T) {
	p := mustProduct(t)
	fields, err := p.UpdateMasterData(map[string]any{"namesEn": "Aromatic", "attributes": map[string]any{"grade": "B"}}, testDID, now)
	if err != nil {
		t.Fatal(err)
	}
	if len(fields) != 2 {
		t.Fatalf("want 2 updated fields, got %v", fields)
	}
	if _, err := p.UpdateMasterData(map[string]any{"gpid": "GP-x-y"}, testDID, now); err == nil {
		t.Fatal("gpid is immutable — updating it must fail")
	}
	if _, err := p.UpdateMasterData(map[string]any{"namesBn": ""}, testDID, now); err == nil {
		t.Fatal("clearing namesBn must fail (R8)")
	}
}

// Money is int64 poisha ONLY; price rules capped at 50; same-tier windows must not overlap.
func TestAddPriceRule(t *testing.T) {
	p := mustProduct(t)
	ok := PriceRule{TierApplicable: "ALL", BasePricePoisha: 12500, ValidFromMs: nowMs, ValidUntilMs: 0}
	if _, err := p.AddPriceRule(ok, now); err != nil {
		t.Fatal(err)
	}
	if _, err := p.AddPriceRule(PriceRule{TierApplicable: "ALL", BasePricePoisha: 0, ValidFromMs: nowMs}, now); err == nil {
		t.Fatal("non-positive poisha must be rejected")
	}
	// overlapping window, same tier
	if _, err := p.AddPriceRule(PriceRule{TierApplicable: "ALL", BasePricePoisha: 130, ValidFromMs: nowMs + 1000, ValidUntilMs: 0}, now); err == nil {
		t.Fatal("overlapping validity for same tier must be rejected")
	}
	// different tier may overlap
	if _, err := p.AddPriceRule(PriceRule{TierApplicable: "BUSINESS", BasePricePoisha: 110, ValidFromMs: nowMs, ValidUntilMs: 0}, now); err != nil {
		t.Fatalf("different tier overlap must be allowed: %v", err)
	}
}

// HIGH-2 review fix: DEPRECATED products are frozen — no new price rules.
func TestAddPriceRuleRejectedWhenDeprecated(t *testing.T) {
	p := mustProduct(t)
	_ = p.Publish(testDID, now)
	_ = p.Deprecate("", "superseded", testDID, 0, now)
	if _, err := p.AddPriceRule(PriceRule{TierApplicable: "ALL", BasePricePoisha: 5, ValidFromMs: nowMs}, now); err == nil {
		t.Fatal("price rule on DEPRECATED product must be rejected")
	}
}

func TestPriceRuleCapAt50(t *testing.T) {
	p := mustProduct(t)
	for i := 0; i < MaxPriceRules; i++ {
		r := PriceRule{TierApplicable: "ALL", BasePricePoisha: 100,
			ValidFromMs: nowMs + int64(i*2000), ValidUntilMs: nowMs + int64(i*2000+1000)}
		if _, err := p.AddPriceRule(r, now); err != nil {
			t.Fatalf("rule %d: %v", i, err)
		}
	}
	over := PriceRule{TierApplicable: "ALL", BasePricePoisha: 100,
		ValidFromMs: nowMs + 999000, ValidUntilMs: nowMs + 999500}
	if _, err := p.AddPriceRule(over, now); err == nil {
		t.Fatalf("rule #%d must exceed the cap", MaxPriceRules+1)
	}
}
