package dkdplatform

import (
	"encoding/json"
	"os"
	"path/filepath"
	"testing"
)

type chVector struct {
	Name      string         `json:"name"`
	Fields    map[string]any `json:"fields"`
	Canonical string         `json:"canonical"`
	Digest    string         `json:"digest"`
}

func loadCHVectors(t *testing.T) []chVector {
	t.Helper()
	p := filepath.Join("..", "testvectors", "custodyhash_vectors.json")
	b, err := os.ReadFile(p)
	if err != nil {
		t.Fatalf("read fixture: %v", err)
	}
	var doc struct {
		Vectors []chVector `json:"vectors"`
	}
	if err := json.Unmarshal(b, &doc); err != nil {
		t.Fatalf("parse fixture: %v", err)
	}
	return doc.Vectors
}

func TestCustodyHashSharedFixture(t *testing.T) {
	for _, v := range loadCHVectors(t) {
		canon := make(map[string]any, len(v.Fields))
		for k, val := range v.Fields {
			if k != "eventHash" {
				canon[k] = val
			}
		}
		got, err := CustodyCanonicalJSON(canon)
		if err != nil {
			t.Fatalf("%s: canonical: %v", v.Name, err)
		}
		if string(got) != v.Canonical {
			t.Errorf("%s canonical mismatch:\n got %s\n exp %s", v.Name, got, v.Canonical)
		}
		h, err := CustodyEventHash(v.Fields)
		if err != nil {
			t.Fatalf("%s: hash: %v", v.Name, err)
		}
		if h != v.Digest {
			t.Errorf("%s digest mismatch: got %s exp %s", v.Name, h, v.Digest)
		}
	}
}

func TestCustodyHashExcludesEventHash(t *testing.T) {
	with := map[string]any{"ppid": "PP-1", "previousHash": "", "eventHash": "ffff"}
	without := map[string]any{"ppid": "PP-1", "previousHash": ""}
	a, _ := CustodyEventHash(with)
	b, _ := CustodyEventHash(without)
	if a != b {
		t.Errorf("eventHash not excluded: %s != %s", a, b)
	}
}

func TestCustodyTV01KnownDigest(t *testing.T) {
	for _, v := range loadCHVectors(t) {
		if v.Name == "TV-01-genesis" && v.Digest != "ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597" {
			t.Fatalf("TV-01 digest drift: %s", v.Digest)
		}
	}
}
