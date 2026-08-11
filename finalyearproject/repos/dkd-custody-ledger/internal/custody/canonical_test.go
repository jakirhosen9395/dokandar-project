package custody

import (
	"encoding/json"
	"regexp"
	"strings"
	"testing"
)

// TV-01 — the PUBLISHED genesis canonical string from CustodyHash Spec v2. This test asserts
// BYTE-EXACT equality: any divergence here breaks cross-language hash parity.
// (The expected digest itself is NEEDS-INFO — deferred by canon to Engineering Foundation
// Appendix B — so we pin the canonical bytes, which fully determine it.)
const tv01Canonical = `{"gpid":"GP-rice-01JABCDEF","holder":"did:dokandar:01JABCDEF","holderRole":"PRODUCER","initializedAt":1750000001000,"ppid":"PP-01JABCDEF","previousHash":"","producedAt":1750000000000,"quantity":5000,"unit":"kg"}`

func tv01Fields() map[string]any {
	return map[string]any{
		"ppid":          "PP-01JABCDEF",
		"gpid":          "GP-rice-01JABCDEF",
		"holder":        "did:dokandar:01JABCDEF",
		"holderRole":    "PRODUCER",
		"quantity":      int64(5000),
		"unit":          "kg",
		"producedAt":    int64(1750000000000),
		"initializedAt": int64(1750000001000),
		"previousHash":  "",
	}
}

func TestTV01CanonicalBytesExact(t *testing.T) {
	got, err := CanonicalJSON(tv01Fields())
	if err != nil {
		t.Fatal(err)
	}
	if string(got) != tv01Canonical {
		t.Fatalf("canonical bytes diverge from the published vector:\n got: %s\nwant: %s", got, tv01Canonical)
	}
}

func TestTV01EventHashShapeAndDeterminism(t *testing.T) {
	h1, err := EventHash(tv01Fields())
	if err != nil {
		t.Fatal(err)
	}
	if !regexp.MustCompile(`^[0-9a-f]{64}$`).MatchString(h1) {
		t.Fatalf("eventHash must be 64-char lowercase hex: %s", h1)
	}
	h2, _ := EventHash(tv01Fields())
	if h1 != h2 {
		t.Fatal("hash must be deterministic")
	}
}

// eventHash is ALWAYS excluded from its own canonical payload.
func TestEventHashExcludesItself(t *testing.T) {
	f := tv01Fields()
	base, _ := EventHash(f)
	f["eventHash"] = "0000000000000000000000000000000000000000000000000000000000000000"
	withField, err := EventHash(f)
	if err != nil {
		t.Fatal(err)
	}
	if base != withField {
		t.Fatal("presence of eventHash field must not change the hash (excluded from canonical)")
	}
	ok, err := VerifyEvent(map[string]any{"a": "b"})
	if err == nil || ok {
		t.Fatal("verify without recorded eventHash must error")
	}
}

func TestVerifyEventRoundTrip(t *testing.T) {
	f := tv01Fields()
	h, _ := EventHash(f)
	f["eventHash"] = h
	ok, err := VerifyEvent(f)
	if err != nil || !ok {
		t.Fatalf("verify: ok=%v err=%v", ok, err)
	}
	f["quantity"] = int64(4999) // tamper
	ok, _ = VerifyEvent(f)
	if ok {
		t.Fatal("tampered payload must fail verification")
	}
}

// C3-F2 determinism guard: the published TV-01 genesis digest must NEVER change. Adding the
// signature/keyId/coSignature/coKeyId exclusions to EventHash must leave every pre-existing
// event digest byte-identical (they carry none of those fields).
func TestTV01DigestUnchanged(t *testing.T) {
	const want = "ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597"
	got, err := EventHash(tv01Fields())
	if err != nil {
		t.Fatal(err)
	}
	if got != want {
		t.Fatalf("TV-01 digest changed — cross-language determinism gate broken:\n got %s\nwant %s", got, want)
	}
}

// C3-F2: the crypto envelope (signature/keyId/coSignature/coKeyId) is excluded from the hash
// EXACTLY like eventHash — an event with and without those fields yields the SAME digest. That
// is what lets both Ed25519 signatures sign a hash equal to the stored chain hash. coSignerDid,
// by contrast, is SEMANTIC and MUST change the digest (it binds the co-signer's identity).
func TestEventHashExcludesSignatureEnvelope(t *testing.T) {
	semantic := map[string]any{
		"ppid": "PP-01JABCDEF", "agentDid": "did:dokandar:agent",
		"signingMode": "CUSTODIAL_SIGNED", "signedAt": int64(1750000003000),
		"previousHash": "abc123", "coSignerDid": "did:dokandar:cosigner",
	}
	base, err := EventHash(semantic)
	if err != nil {
		t.Fatal(err)
	}
	withEnvelope := map[string]any{}
	for k, v := range semantic {
		withEnvelope[k] = v
	}
	withEnvelope["signature"] = "c2lnbmF0dXJl"
	withEnvelope["keyId"] = "key-agent-1"
	withEnvelope["coSignature"] = "Y29zaWc="
	withEnvelope["coKeyId"] = "key-co-1"
	withEnvelope["eventHash"] = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff"
	got, err := EventHash(withEnvelope)
	if err != nil {
		t.Fatal(err)
	}
	if got != base {
		t.Fatalf("signature envelope must NOT affect the hash:\nbase=%s\n got=%s", base, got)
	}
	changed := map[string]any{}
	for k, v := range semantic {
		changed[k] = v
	}
	changed["coSignerDid"] = "did:dokandar:someone-else"
	if other, _ := EventHash(changed); other == base {
		t.Fatal("coSignerDid is semantic and must change the hash (it is NOT excluded)")
	}
}

// R2: null members omitted; absent and null hash identically (schema evolution rule).
func TestNullOmission(t *testing.T) {
	withNull, err := CanonicalJSON(map[string]any{"a": "x", "b": nil})
	if err != nil {
		t.Fatal(err)
	}
	if string(withNull) != `{"a":"x"}` {
		t.Fatalf("null member must be omitted: %s", withNull)
	}
	h1, _ := EventHash(map[string]any{"a": "x", "b": nil})
	h2, _ := EventHash(map[string]any{"a": "x"})
	if h1 != h2 {
		t.Fatal("absent and null must hash identically")
	}
}

// R3+R9: keys sorted at every depth; R8: arrays keep order.
func TestNestedSortingAndArrayOrder(t *testing.T) {
	got, err := CanonicalJSON(map[string]any{
		"z": map[string]any{"b": int64(2), "a": int64(1)},
		"a": []any{map[string]any{"y": true, "x": false}, "second"},
	})
	if err != nil {
		t.Fatal(err)
	}
	want := `{"a":[{"x":false,"y":true},"second"],"z":{"a":1,"b":2}}`
	if string(got) != want {
		t.Fatalf("got %s want %s", got, want)
	}
}

// R5: no \uXXXX for code points < U+0080 (HTML chars stay literal); Bangla stays raw UTF-8.
func TestStringEncodingR5(t *testing.T) {
	got, err := CanonicalJSON(map[string]any{"s": `a<b&c>"d"\`, "bn": "চাল"})
	if err != nil {
		t.Fatal(err)
	}
	s := string(got)
	if strings.Contains(s, "u003c") || strings.Contains(s, "u0026") || strings.Contains(s, "u003e") {
		t.Fatalf("uXXXX escapes below U+0080 are forbidden (R5): %s", s)
	}
	if !strings.Contains(s, "<") || !strings.Contains(s, "&") {
		t.Fatalf("HTML chars must appear literally (R5): %s", s)
	}
	if !strings.Contains(s, "চাল") {
		t.Fatalf("non-ASCII must stay raw UTF-8: %s", s)
	}
	var back map[string]string
	if err := json.Unmarshal(got, &back); err != nil {
		t.Fatalf("canonical output must remain valid JSON: %v", err)
	}
	if back["s"] != `a<b&c>"d"\` {
		t.Fatalf("string round-trip: %q", back["s"])
	}
}

// R6: integers plain decimal; integral floats (post-decode) normalize; non-integral rejected.
func TestNumberEncodingR6(t *testing.T) {
	got, _ := CanonicalJSON(map[string]any{"n": int64(5000), "m": float64(7)})
	if string(got) != `{"m":7,"n":5000}` {
		t.Fatalf("numbers: %s", got)
	}
	if _, err := CanonicalJSON(map[string]any{"bad": 3.14}); err == nil {
		t.Fatal("non-integral float must be rejected")
	}
}

// Round-trip stability: decoding the canonical JSON and re-canonicalizing yields identical bytes
// (this is what makes verification possible after a store/DB round trip).
func TestDecodeRecanonicalizeStable(t *testing.T) {
	orig, _ := CanonicalJSON(tv01Fields())
	var decoded map[string]any
	if err := json.Unmarshal(orig, &decoded); err != nil {
		t.Fatal(err)
	}
	again, err := CanonicalJSON(decoded)
	if err != nil {
		t.Fatal(err)
	}
	if string(orig) != string(again) {
		t.Fatalf("re-canonicalization diverged:\n%s\n%s", orig, again)
	}
}
