package dkdplatform

import "testing"

func TestUUIDv7GeneratesValid(t *testing.T) {
	for i := 0; i < 1000; i++ {
		id := NewUUIDv7()
		if len(id) != 36 {
			t.Fatalf("generated id %q not 36 chars", id)
		}
		if err := ValidateUUIDv7(id); err != nil {
			t.Fatalf("generated id %q failed v7 validation: %v", id, err)
		}
	}
}

func TestValidateUUIDv7RejectsNonV7(t *testing.T) {
	cases := map[string]string{
		"v4":            "550e8400-e29b-41d4-a716-446655440000", // version nibble 4
		"all-zero":      "00000000-0000-0000-0000-000000000000",
		"garbage":       "not-a-uuid",
		"short":         "0189d6a0-0000-7000-8000",
		"non-hex":       "0189d6a0-zzzz-7000-8000-000000000000",
		"bad-variant":   "0189d6a0-0000-7000-0000-000000000000", // variant nibble 0
		"missing-dash":  "0189d6a000007000800000000000000000zz",
		"empty":         "",
	}
	for name, s := range cases {
		if err := ValidateUUIDv7(s); err == nil {
			t.Errorf("%s: expected rejection of %q", name, s)
		}
	}
}

func TestValidateUUIDv7AcceptsKnownV7(t *testing.T) {
	// RFC 9562 example v7 (version nibble 7, variant 8..b).
	if err := ValidateUUIDv7("017f22e2-79b0-7cc3-98c4-dc0c0c07398f"); err != nil {
		t.Fatalf("known-good v7 rejected: %v", err)
	}
}

func TestPrefixedIDValidatesEmbeddedV7(t *testing.T) {
	good := NewUUIDv7()
	if _, err := NewDID(DIDPrefix + good); err != nil {
		t.Fatalf("DID with v7 body should pass: %v", err)
	}
	if _, err := NewORD(ORDPrefix + good); err != nil {
		t.Fatalf("ORD with v7 body should pass: %v", err)
	}
	// v4 body must be rejected by the prefixed helper.
	if _, err := NewORD(ORDPrefix + "550e8400-e29b-41d4-a716-446655440000"); err == nil {
		t.Fatal("ORD with v4 body should be rejected")
	}
	// Category-segmented catalog id keeps the trailing UUID pinned to v7.
	if _, err := NewGPID(GPIDPrefix + "electronics-" + good); err != nil {
		t.Fatalf("GPID with category + v7 body should pass: %v", err)
	}
	if _, err := NewGPID(GPIDPrefix + "electronics-deadbeef"); err == nil {
		t.Fatal("GPID with non-v7 trailing body should be rejected")
	}
}
