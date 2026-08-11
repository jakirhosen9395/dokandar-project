package clients

import (
	"context"
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"testing"
)

const (
	testPPID = "PP-0198c0de-0000-7000-8000-0000000000c1"
	testFrom = "did:dokandar:0198c0de-0000-7000-8000-0000000000a1"
	testTo   = "did:dokandar:0198c0de-0000-7000-8000-0000000000b2"
	testRole = "CONSUMER"
	testOrd  = "ORD-0198c0de-0000-7000-8000-0000000000d4"
	testAt   = int64(1750000000000)
)

// captureCustody stands in for custody's /transfer, capturing the POSTed JSON body.
func captureCustody(t *testing.T, captured *map[string]any) *httptest.Server {
	t.Helper()
	return httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		b, _ := io.ReadAll(r.Body)
		var m map[string]any
		if err := json.Unmarshal(b, &m); err != nil {
			t.Errorf("custody stub: bad body: %v", err)
		}
		*captured = m
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte(`{"success":true}`))
	}))
}

func attestation() Attestation {
	return Attestation{PPID: testPPID, FromHolder: testFrom, ToHolder: testTo, ToHolderRole: testRole}
}

// C3-F2e: when an attestation key is configured, AttestDelivery MUST include a base64 Ed25519
// attestationSignature that verifies against the corresponding PUBLIC key over the exact POD-ATTEST
// message — i.e. the same bytes custody reconstructs from the request path + body.
func TestAttestDeliverySignsWhenKeySet(t *testing.T) {
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	seedB64 := base64.StdEncoding.EncodeToString(priv.Seed())

	var captured map[string]any
	srv := captureCustody(t, &captured)
	defer srv.Close()

	h := New("", srv.URL, seedB64, nil)
	status, err := h.AttestDelivery(context.Background(), "SHP-1", testOrd, testAt, attestation())
	if err != nil || status != http.StatusOK {
		t.Fatalf("AttestDelivery: status=%d err=%v", status, err)
	}

	sigB64, ok := captured["attestationSignature"].(string)
	if !ok || sigB64 == "" {
		t.Fatalf("attestationSignature must be present in the payload; got %v", captured)
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		t.Fatalf("attestationSignature must be base64-std: %v", err)
	}
	// The signature must verify over the documented POD-ATTEST message (path ppid + body fields).
	msg := attestationMessage(testPPID, testFrom, testTo, testRole, testOrd, testAt)
	if !ed25519.Verify(pub, msg, sig) {
		t.Fatal("attestationSignature must verify against the authority pubkey over the POD-ATTEST message")
	}
	// The body must also carry the referenceOrd + transferredAt custody recomputes the message from.
	if captured["referenceOrd"] != testOrd {
		t.Fatalf("body must carry referenceOrd=%s; got %v", testOrd, captured["referenceOrd"])
	}
	if int64(captured["transferredAt"].(float64)) != testAt {
		t.Fatalf("body must carry transferredAt=%d; got %v", testAt, captured["transferredAt"])
	}
}

// With no key configured, the payload MUST NOT carry an attestationSignature (pre-C3-F2e shape),
// so non-POD environments still function unchanged.
func TestAttestDeliveryNoSignatureWhenKeyUnset(t *testing.T) {
	var captured map[string]any
	srv := captureCustody(t, &captured)
	defer srv.Close()

	h := New("", srv.URL, "", nil)
	if _, err := h.AttestDelivery(context.Background(), "SHP-1", testOrd, testAt, attestation()); err != nil {
		t.Fatalf("AttestDelivery: %v", err)
	}
	if _, present := captured["attestationSignature"]; present {
		t.Fatalf("no attestationSignature must be sent when the key is unset; got %v", captured)
	}
}

// A 64-byte full Ed25519 private key (not just a 32-byte seed) is also accepted.
func TestNewAcceptsFullPrivateKey(t *testing.T) {
	_, priv, _ := ed25519.GenerateKey(rand.Reader)
	fullB64 := base64.StdEncoding.EncodeToString(priv)
	h := New("", "http://custody.local", fullB64, nil)
	if h.attestKey == nil {
		t.Fatal("a 64-byte full Ed25519 key must be accepted")
	}
}

// An unparseable key disables signing but never panics/fatals (non-POD envs still boot).
func TestNewIgnoresBadPrivateKey(t *testing.T) {
	h := New("", "http://custody.local", "not-base64!!!", nil)
	if h.attestKey != nil {
		t.Fatal("an invalid key must leave signing disabled")
	}
}
