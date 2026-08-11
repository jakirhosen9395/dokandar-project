package catalog

import (
	"strings"
	"testing"
)

// GPID format is frozen in ids.yaml: GP-{categoryCode}-{uuid7}.
func TestNewGPID7Format(t *testing.T) {
	g, err := NewGPID7("rice")
	if err != nil {
		t.Fatal(err)
	}
	s := string(g)
	if !strings.HasPrefix(s, "GP-rice-") {
		t.Fatalf("prefix: %s", s)
	}
	if err := ValidateGPID(s); err != nil {
		t.Fatalf("self-validate: %v", err)
	}
}

func TestNewGPID7UUIDv7VersionBits(t *testing.T) {
	g, _ := NewGPID7("jute")
	u := string(g)[len("GP-jute-"):]
	// canonical uuid: 8-4-4-4-12; version nibble at position 14 must be '7'
	if len(u) != 36 || u[14] != '7' {
		t.Fatalf("not a uuidv7: %s", u)
	}
	if variant := u[19]; variant != '8' && variant != '9' && variant != 'a' && variant != 'b' {
		t.Fatalf("bad variant nibble: %c", variant)
	}
}

func TestNewGPID7RejectsBadCategoryCode(t *testing.T) {
	for _, bad := range []string{"", "RICE", "has space", "toolongcategorycode", "a-b", "বাংলা"} {
		if _, err := NewGPID7(bad); err == nil {
			t.Fatalf("category code %q must be rejected", bad)
		}
	}
}

func TestValidateGPID(t *testing.T) {
	ok, _ := NewGPID7("fish")
	cases := []struct {
		in      string
		wantErr bool
	}{
		{string(ok), false},
		{"GP-fish-not-a-uuid", true},
		{"GPID-0198c0de-0000-7000-8000-000000000000", true}, // wrong prefix form
		{"GP--0198c0de-0000-7000-8000-000000000000", true},  // empty category
		{"", true},
	}
	for _, tc := range cases {
		if err := ValidateGPID(tc.in); (err != nil) != tc.wantErr {
			t.Fatalf("%q: err=%v wantErr=%v", tc.in, err, tc.wantErr)
		}
	}
}

func TestGPIDsAreUnique(t *testing.T) {
	seen := map[string]bool{}
	for i := 0; i < 200; i++ {
		g, err := NewGPID7("rice")
		if err != nil {
			t.Fatal(err)
		}
		if seen[string(g)] {
			t.Fatal("duplicate GPID generated")
		}
		seen[string(g)] = true
	}
}
