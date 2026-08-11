// Package catalog implements the Product Master Data aggregate (Context #2, DM canon):
// lifecycle DRAFT -> PUBLISHED -> DEPRECATED, price rules in int64 poisha, GPID sole issuance (R7),
// Bangla-first names (R8). SA-layer extras (PENDING_REVIEW/MERGED_AWAY, BatchIdentity, GPID merge)
// are NEEDS-INFO extension points and deliberately absent.
package catalog

import (
	"fmt"
	"sort"
	"strings"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

type Status string

const (
	StatusDraft      Status = "DRAFT"
	StatusPublished  Status = "PUBLISHED"
	StatusDeprecated Status = "DEPRECATED"
)

// MaxPriceRules is the DM invariant MAX_PRICE_RULES.
const MaxPriceRules = 50

// PriceRule is a value object; money is int64 poisha ONLY. TierApplicable values are a
// NEEDS-INFO enum in canon (UNVERIFIED|BASIC|FULL|BUSINESS|ALL per DM prose) — stored as string.
type PriceRule struct {
	RuleID          string `json:"ruleId"`
	TierApplicable  string `json:"tierApplicable"`
	BasePricePoisha int64  `json:"basePricePoisha"`
	ValidFromMs     int64  `json:"validFrom"`
	ValidUntilMs    int64  `json:"validUntil"` // 0 = open-ended
}

type Product struct {
	GPID         dkd.GPID       `json:"gpid"`
	CategoryPath []string       `json:"categoryPath"`
	NamesBn      string         `json:"namesBn"`
	NamesEn      string         `json:"namesEn,omitempty"`
	BaseUnit     string         `json:"baseUnit"`
	Attributes   map[string]any `json:"attributes,omitempty"`
	PriceRules   []PriceRule    `json:"priceRules,omitempty"`
	Status       Status         `json:"status"`
	CreatedBy    string         `json:"createdBy"`
	CreatedAtMs  int64          `json:"createdAt"`
	UpdatedAtMs  int64          `json:"updatedAt"`
	Version      int64          `json:"version"`
}

type NewProductInput struct {
	CategoryPath []string
	CategoryCode string
	NamesBn      string
	NamesEn      string
	BaseUnit     string
	Attributes   map[string]any
	CreatedBy    string
}

type NowFunc func() int64

func validDID(s string) error {
	if _, err := dkd.NewDID(s); err != nil {
		return fmt.Errorf("catalog: invalid DID: %w", err)
	}
	return nil
}

func NewProduct(in NewProductInput, now NowFunc) (*Product, error) {
	if strings.TrimSpace(in.NamesBn) == "" {
		return nil, fmt.Errorf("catalog: namesBn is required (Bangla-first, R8)")
	}
	if len(in.CategoryPath) == 0 {
		return nil, fmt.Errorf("catalog: categoryPath is required")
	}
	if strings.TrimSpace(in.BaseUnit) == "" {
		return nil, fmt.Errorf("catalog: baseUnit is required")
	}
	if err := validDID(in.CreatedBy); err != nil {
		return nil, err
	}
	gpid, err := NewGPID7(in.CategoryCode)
	if err != nil {
		return nil, err
	}
	ts := now()
	attrs := map[string]any{}
	for k, v := range in.Attributes {
		attrs[k] = v
	}
	return &Product{
		GPID:         gpid,
		CategoryPath: append([]string(nil), in.CategoryPath...),
		NamesBn:      in.NamesBn,
		NamesEn:      in.NamesEn,
		BaseUnit:     in.BaseUnit,
		Attributes:   attrs,
		Status:       StatusDraft,
		CreatedBy:    in.CreatedBy,
		CreatedAtMs:  ts,
		UpdatedAtMs:  ts,
		Version:      1,
	}, nil
}

func (p *Product) Publish(by string, now NowFunc) error {
	if err := validDID(by); err != nil {
		return err
	}
	if p.Status != StatusDraft {
		return fmt.Errorf("catalog: only DRAFT can be published (status=%s)", p.Status)
	}
	p.Status = StatusPublished
	p.UpdatedAtMs = now()
	p.Version++
	return nil
}

// Deprecate enforces the M5 invariant: no active custody passports may reference the GPID.
func (p *Product) Deprecate(successorGpid, reason, by string, activePassports int64, now NowFunc) error {
	if err := validDID(by); err != nil {
		return err
	}
	if p.Status != StatusPublished {
		return fmt.Errorf("catalog: only PUBLISHED can be deprecated (status=%s)", p.Status)
	}
	if activePassports > 0 {
		return fmt.Errorf("catalog: %d active custody passports reference %s (M5 blocks deprecation)", activePassports, p.GPID)
	}
	if successorGpid != "" {
		if err := ValidateGPID(successorGpid); err != nil {
			return fmt.Errorf("catalog: successorGpid: %w", err)
		}
	}
	if strings.TrimSpace(reason) == "" {
		return fmt.Errorf("catalog: deprecation reason is required")
	}
	p.Status = StatusDeprecated
	p.UpdatedAtMs = now()
	p.Version++
	return nil
}

// UpdateMasterData applies a whitelisted field patch and returns the sorted list of changed fields.
// GPID is immutable; namesBn may never be cleared (R8); DEPRECATED products are frozen.
func (p *Product) UpdateMasterData(changes map[string]any, by string, now NowFunc) ([]string, error) {
	if err := validDID(by); err != nil {
		return nil, err
	}
	if p.Status == StatusDeprecated {
		return nil, fmt.Errorf("catalog: DEPRECATED product master data is frozen")
	}
	if len(changes) == 0 {
		return nil, fmt.Errorf("catalog: no changes supplied")
	}
	var fields []string
	for k, v := range changes {
		switch k {
		case "namesBn":
			s, _ := v.(string)
			if strings.TrimSpace(s) == "" {
				return nil, fmt.Errorf("catalog: namesBn may not be cleared (R8)")
			}
			p.NamesBn = s
		case "namesEn":
			s, _ := v.(string)
			p.NamesEn = s
		case "attributes":
			m, ok := v.(map[string]any)
			if !ok {
				return nil, fmt.Errorf("catalog: attributes must be an object")
			}
			p.Attributes = m
		default:
			return nil, fmt.Errorf("catalog: field %q is not updatable (gpid/status/lifecycle are managed)", k)
		}
		fields = append(fields, k)
	}
	sort.Strings(fields)
	p.UpdatedAtMs = now()
	p.Version++
	return fields, nil
}

func (r PriceRule) overlaps(o PriceRule) bool {
	if r.TierApplicable != o.TierApplicable {
		return false
	}
	rEnd, oEnd := r.ValidUntilMs, o.ValidUntilMs
	const inf = int64(1<<62 - 1)
	if rEnd == 0 {
		rEnd = inf
	}
	if oEnd == 0 {
		oEnd = inf
	}
	return r.ValidFromMs < oEnd && o.ValidFromMs < rEnd
}

// AddPriceRule validates and appends a rule, assigning a UUIDv7 ruleId when absent.
// DEPRECATED products are frozen: no new price rules (mirrors UpdateMasterData).
func (p *Product) AddPriceRule(r PriceRule, now NowFunc) (PriceRule, error) {
	if p.Status == StatusDeprecated {
		return PriceRule{}, fmt.Errorf("catalog: DEPRECATED product is frozen (no new price rules)")
	}
	if strings.TrimSpace(r.TierApplicable) == "" {
		return PriceRule{}, fmt.Errorf("catalog: tierApplicable is required")
	}
	if r.BasePricePoisha <= 0 {
		return PriceRule{}, fmt.Errorf("catalog: basePricePoisha must be positive int64 poisha")
	}
	if r.ValidFromMs <= 0 {
		return PriceRule{}, fmt.Errorf("catalog: validFrom (unix-ms) is required")
	}
	if r.ValidUntilMs != 0 && r.ValidUntilMs <= r.ValidFromMs {
		return PriceRule{}, fmt.Errorf("catalog: validUntil must be 0 (open) or after validFrom")
	}
	if len(p.PriceRules) >= MaxPriceRules {
		return PriceRule{}, fmt.Errorf("catalog: MAX_PRICE_RULES (%d) reached", MaxPriceRules)
	}
	for _, ex := range p.PriceRules {
		if r.overlaps(ex) {
			return PriceRule{}, fmt.Errorf("catalog: overlapping validity window for tier %s", r.TierApplicable)
		}
	}
	if r.RuleID == "" {
		r.RuleID = uuidv7New()
	}
	p.PriceRules = append(p.PriceRules, r)
	p.UpdatedAtMs = now()
	p.Version++
	return r, nil
}
