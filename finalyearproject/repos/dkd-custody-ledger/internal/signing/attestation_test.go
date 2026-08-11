package signing

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"strconv"
	"testing"
)

// mkAttestation builds a valid attestation-authority POD-ATTEST signature (C3-F2e): the trusted
// authority (here a freshly generated Ed25519 key) signs the canonical POD-ATTEST message a
// logistics client would compute for a reference-linked custody move.
func mkAttestation(t *testing.T) (authority ed25519.PublicKey, sigB64 string, msg []byte) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	msg = AttestationMessage(
		"PP-0198c0de-0000-7000-8000-0000000000c1", fromDID, toDID, "CONSUMER",
		"ORD-0198c0de-0000-7000-8000-0000000000a1", 1750000009000)
	return pub, base64.StdEncoding.EncodeToString(ed25519.Sign(priv, msg)), msg
}

// AttestationMessage must be the EXACT, documented, newline-delimited canonical form — this pins the
// byte layout so custody and the logistics client can never silently drift apart.
func TestAttestationMessageCanonicalForm(t *testing.T) {
	ppid := "PP-0198c0de-0000-7000-8000-0000000000c1"
	got := string(AttestationMessage(ppid, fromDID, toDID, "CONSUMER", "ORD-xyz", 1750000009000))
	want := "POD-ATTEST\n" + ppid + "\n" + fromDID + "\n" + toDID + "\n" + "CONSUMER" + "\n" +
		"ORD-xyz" + "\n" + strconv.FormatInt(1750000009000, 10)
	if got != want {
		t.Fatalf("attestation message layout drifted:\n got=%q\nwant=%q", got, want)
	}
}

func TestVerifyAttestationValid(t *testing.T) {
	authority, sig, msg := mkAttestation(t)
	if err := VerifyAttestation(authority, msg, sig); err != nil {
		t.Fatalf("valid attestation-authority signature must verify: %v", err)
	}
}

// A signature by ANY key other than the configured authority (a forged attestation) is rejected —
// this is the guard that stops a leaked/rogue signer from moving custody.
func TestVerifyAttestationWrongAuthorityRejected(t *testing.T) {
	authority, _, msg := mkAttestation(t)
	_, strayPriv, _ := ed25519.GenerateKey(rand.Reader)
	forged := base64.StdEncoding.EncodeToString(ed25519.Sign(strayPriv, msg))
	if err := VerifyAttestation(authority, msg, forged); !errors.Is(err, ErrAttestationSig) {
		t.Fatalf("attestation signed by a non-authority key must be rejected, got %v", err)
	}
}

// Any change to the signed message (e.g. a swapped toHolder) invalidates the signature.
func TestVerifyAttestationTamperedMessageRejected(t *testing.T) {
	authority, sig, _ := mkAttestation(t)
	tampered := AttestationMessage(
		"PP-0198c0de-0000-7000-8000-0000000000c1", fromDID,
		"did:dokandar:0198c0de-0000-7000-8000-00000000beef", // different toHolder
		"CONSUMER", "ORD-0198c0de-0000-7000-8000-0000000000a1", 1750000009000)
	if err := VerifyAttestation(authority, tampered, sig); !errors.Is(err, ErrAttestationSig) {
		t.Fatalf("tampered attestation message must fail verification, got %v", err)
	}
}

// Fail closed: with no authority key configured, attestation mode is unavailable — never open.
func TestVerifyAttestationFailsClosedWhenUnset(t *testing.T) {
	_, sig, msg := mkAttestation(t)
	if err := VerifyAttestation(nil, msg, sig); !errors.Is(err, ErrAttestationAuthorityUnset) {
		t.Fatalf("unset attestation authority must fail closed, got %v", err)
	}
}

func TestVerifyAttestationBadEncodingRejected(t *testing.T) {
	authority, _, msg := mkAttestation(t)
	if err := VerifyAttestation(authority, msg, "not-base64!!!"); !errors.Is(err, ErrBadSignatureEncoding) {
		t.Fatalf("non-base64 attestation signature must be rejected, got %v", err)
	}
}
