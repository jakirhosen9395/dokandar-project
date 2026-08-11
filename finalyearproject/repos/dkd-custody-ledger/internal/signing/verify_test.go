package signing

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"testing"
)

const (
	agentDID = "did:dokandar:0198c0de-0000-7000-8000-00000000000a"
	coDID    = "did:dokandar:0198c0de-0000-7000-8000-00000000000b"
)

// mkValidReq builds a fully valid dual-signed request plus the two registry entries, signing the
// recomputed event hash with freshly generated Ed25519 private keys — exactly what a client does.
func mkValidReq(t *testing.T) (Request, ResolvedKey, ResolvedKey) {
	t.Helper()
	apub, apriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	cpub, cpriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	r := Request{
		PPID: "PP-0198c0de-0000-7000-8000-00000000000c", AgentDid: agentDID, CoSignerDid: coDID,
		SignedAt: 1750000003000, PreviousHash: "genesis-head-hash",
	}
	h, err := EventHashHex(r)
	if err != nil {
		t.Fatal(err)
	}
	r.Signature = base64.StdEncoding.EncodeToString(ed25519.Sign(apriv, []byte(h)))
	r.CoSignature = base64.StdEncoding.EncodeToString(ed25519.Sign(cpriv, []byte(h)))
	return r, ResolvedKey{PublicKey: apub, BoundDID: agentDID}, ResolvedKey{PublicKey: cpub, BoundDID: coDID}
}

func TestVerifyValidDualSign(t *testing.T) {
	r, ak, ck := mkValidReq(t)
	if err := Verify(r, ak, ck); err != nil {
		t.Fatalf("valid dual co-sign must verify: %v", err)
	}
}

// Tampering with any semantic field changes the recomputed hash, so the signatures no longer
// verify — the core integrity guarantee.
func TestVerifyTamperedPayloadRejected(t *testing.T) {
	r, ak, ck := mkValidReq(t)
	r.SignedAt++ // signatures were made over the ORIGINAL hash
	if err := Verify(r, ak, ck); !errors.Is(err, ErrAgentSig) {
		t.Fatalf("tampered payload must fail signature verification, got %v", err)
	}
}

// A signature from a key whose bound_did != the acting DID is rejected (key/DID binding).
func TestVerifyWrongSignerRejected(t *testing.T) {
	r, ak, ck := mkValidReq(t)
	ak.BoundDID = "did:dokandar:0198c0de-0000-7000-8000-0000000000ff"
	if err := Verify(r, ak, ck); !errors.Is(err, ErrAgentBinding) {
		t.Fatalf("agent key not bound to agentDid must be rejected, got %v", err)
	}
}

func TestVerifyCoSignerBindingRejected(t *testing.T) {
	r, ak, ck := mkValidReq(t)
	ck.BoundDID = "did:dokandar:0198c0de-0000-7000-8000-0000000000fe"
	if err := Verify(r, ak, ck); !errors.Is(err, ErrCoSignerBinding) {
		t.Fatalf("co-signer key not bound to coSignerDid must be rejected, got %v", err)
	}
}

// Four-eyes (R4/BR-005): the co-signer must differ from the acting agent.
func TestVerifyFourEyesRejected(t *testing.T) {
	r, ak, ck := mkValidReq(t)
	r.CoSignerDid = r.AgentDid
	ck.BoundDID = r.AgentDid
	if err := Verify(r, ak, ck); !errors.Is(err, ErrSameSigner) {
		t.Fatalf("four-eyes: identical agent and co-signer must be rejected, got %v", err)
	}
}

func TestVerifyBadCoSignatureRejected(t *testing.T) {
	r, ak, ck := mkValidReq(t)
	r.CoSignature = base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize)) // zero sig
	if err := Verify(r, ak, ck); !errors.Is(err, ErrCoSig) {
		t.Fatalf("invalid co-signature must be rejected, got %v", err)
	}
}

func TestDecodePublicKey(t *testing.T) {
	pub, _, _ := ed25519.GenerateKey(rand.Reader)
	got, err := DecodePublicKey(base64.StdEncoding.EncodeToString(pub))
	if err != nil || len(got) != ed25519.PublicKeySize {
		t.Fatalf("valid 32-byte key must decode: %v", err)
	}
	if _, err := DecodePublicKey("not-base64!!!"); !errors.Is(err, ErrBadPublicKey) {
		t.Fatal("non-base64 must be rejected")
	}
	if _, err := DecodePublicKey(base64.StdEncoding.EncodeToString([]byte("short"))); !errors.Is(err, ErrBadPublicKey) {
		t.Fatal("wrong-length key must be rejected")
	}
}
