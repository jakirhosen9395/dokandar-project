package signing

import (
	"crypto/ed25519"
	"crypto/rand"
	"encoding/base64"
	"errors"
	"testing"
)

const (
	fromDID = "did:dokandar:0198c0de-0000-7000-8000-0000000000f1"
	toDID   = "did:dokandar:0198c0de-0000-7000-8000-0000000000f2"
)

// mkValidTransfer builds a fully valid dual-signed CUSTODY_TRANSFER: the releasing custodian
// (fromHolder) and the receiving custodian (toHolder) each Ed25519-sign the transfer eventHash,
// exactly as two clients would after GETting the passport head.
func mkValidTransfer(t *testing.T) (TransferRequest, ResolvedKey, ResolvedKey, ed25519.PrivateKey, ed25519.PrivateKey) {
	t.Helper()
	fpub, fpriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tpub, tpriv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	r := TransferRequest{
		PPID: "PP-0198c0de-0000-7000-8000-0000000000c1", GPID: "GP-rice-0198c0de",
		FromHolder: fromDID, ToHolder: toDID, ToHolderRole: "TRADER",
		Quantity: 5000, Unit: "kg", TransferredAt: 1750000005000,
		PreviousHash: "genesis-head-hash", ReferenceOrd: "ORD-abc",
	}
	h, err := TransferEventHashHex(r)
	if err != nil {
		t.Fatal(err)
	}
	r.FromSignature = base64.StdEncoding.EncodeToString(ed25519.Sign(fpriv, []byte(h)))
	r.ToSignature = base64.StdEncoding.EncodeToString(ed25519.Sign(tpriv, []byte(h)))
	return r, ResolvedKey{PublicKey: fpub, BoundDID: fromDID}, ResolvedKey{PublicKey: tpub, BoundDID: toDID}, fpriv, tpriv
}

func TestVerifyTransferValid(t *testing.T) {
	r, fk, tk, _, _ := mkValidTransfer(t)
	if err := VerifyTransfer(r, fk, tk); err != nil {
		t.Fatalf("valid dual-signed transfer must verify: %v", err)
	}
}

// Unsigned (empty signatures) must be rejected — custody may not move without both signatures.
func TestVerifyTransferUnsignedRejected(t *testing.T) {
	r, fk, tk, _, _ := mkValidTransfer(t)
	r.FromSignature = ""
	r.ToSignature = ""
	if err := VerifyTransfer(r, fk, tk); !errors.Is(err, ErrFromSig) {
		t.Fatalf("unsigned transfer must be rejected, got %v", err)
	}
}

// Any tampered semantic field changes the recomputed hash, so the signatures no longer verify.
func TestVerifyTransferTamperedRejected(t *testing.T) {
	r, fk, tk, _, _ := mkValidTransfer(t)
	r.Quantity++ // signatures were made over the ORIGINAL hash
	if err := VerifyTransfer(r, fk, tk); !errors.Is(err, ErrFromSig) {
		t.Fatalf("tampered transfer must fail signature verification, got %v", err)
	}
}

// A from-key whose bound_did != fromHolder is rejected even if the raw math would verify.
func TestVerifyTransferFromBindingRejected(t *testing.T) {
	r, fk, tk, _, _ := mkValidTransfer(t)
	fk.BoundDID = "did:dokandar:0198c0de-0000-7000-8000-0000000000ff"
	if err := VerifyTransfer(r, fk, tk); !errors.Is(err, ErrFromBinding) {
		t.Fatalf("from-key not bound to fromHolder must be rejected, got %v", err)
	}
}

func TestVerifyTransferToBindingRejected(t *testing.T) {
	r, fk, tk, _, _ := mkValidTransfer(t)
	tk.BoundDID = "did:dokandar:0198c0de-0000-7000-8000-0000000000fe"
	if err := VerifyTransfer(r, fk, tk); !errors.Is(err, ErrToBinding) {
		t.Fatalf("to-key not bound to toHolder must be rejected, got %v", err)
	}
}

// A wrong-party from-signature (signed by a stray key that IS bound to fromHolder in the registry
// entry, but whose private key differs) fails Ed25519 verification.
func TestVerifyTransferWrongFromSignatureRejected(t *testing.T) {
	r, fk, tk, _, _ := mkValidTransfer(t)
	_, strayPriv, _ := ed25519.GenerateKey(rand.Reader)
	h, _ := TransferEventHashHex(r)
	r.FromSignature = base64.StdEncoding.EncodeToString(ed25519.Sign(strayPriv, []byte(h)))
	if err := VerifyTransfer(r, fk, tk); !errors.Is(err, ErrFromSig) {
		t.Fatalf("from-signature from a non-matching private key must be rejected, got %v", err)
	}
}

func TestVerifyTransferWrongToSignatureRejected(t *testing.T) {
	r, fk, tk, _, _ := mkValidTransfer(t)
	r.ToSignature = base64.StdEncoding.EncodeToString(make([]byte, ed25519.SignatureSize)) // zero sig
	if err := VerifyTransfer(r, fk, tk); !errors.Is(err, ErrToSig) {
		t.Fatalf("invalid to-signature must be rejected, got %v", err)
	}
}

// --- C3-F2c: CA-signed signer-key binding root of trust ---

func mkCA(t *testing.T) (ed25519.PublicKey, ed25519.PrivateKey) {
	t.Helper()
	pub, priv, err := ed25519.GenerateKey(rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	return pub, priv
}

func TestVerifyCABindingValid(t *testing.T) {
	caPub, caPriv := mkCA(t)
	keyID, pubKey, did := "key-1", "cHVibGljLWtleQ==", fromDID
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(caPriv, CABindingMessage(keyID, pubKey, did)))
	if err := VerifyCABinding(caPub, keyID, pubKey, did, sig); err != nil {
		t.Fatalf("valid CA-signed binding must verify: %v", err)
	}
}

// Fail closed: with no trust anchor configured, EVERY binding is rejected (never open).
func TestVerifyCABindingFailsClosedWhenUnset(t *testing.T) {
	_, caPriv := mkCA(t)
	keyID, pubKey, did := "key-1", "cHVibGljLWtleQ==", fromDID
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(caPriv, CABindingMessage(keyID, pubKey, did)))
	if err := VerifyCABinding(nil, keyID, pubKey, did, sig); !errors.Is(err, ErrTrustAnchorUnset) {
		t.Fatalf("unset trust anchor must fail closed, got %v", err)
	}
}

// A signature by a NON-CA key (a caller trying to self-authorize) is rejected.
func TestVerifyCABindingNonCAKeyRejected(t *testing.T) {
	caPub, _ := mkCA(t)
	_, impostorPriv, _ := ed25519.GenerateKey(rand.Reader)
	keyID, pubKey, did := "key-1", "cHVibGljLWtleQ==", fromDID
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(impostorPriv, CABindingMessage(keyID, pubKey, did)))
	if err := VerifyCABinding(caPub, keyID, pubKey, did, sig); !errors.Is(err, ErrCASig) {
		t.Fatalf("non-CA signature must be rejected, got %v", err)
	}
}

// A binding with NO signature is rejected.
func TestVerifyCABindingMissingSignatureRejected(t *testing.T) {
	caPub, _ := mkCA(t)
	if err := VerifyCABinding(caPub, "key-1", "cHVibGljLWtleQ==", fromDID, ""); err == nil {
		t.Fatal("missing CA signature must be rejected")
	}
}

// Tampering the bound DID after signing (bind a key to a DID the CA did not authorize) is rejected.
func TestVerifyCABindingTamperedDIDRejected(t *testing.T) {
	caPub, caPriv := mkCA(t)
	keyID, pubKey := "key-1", "cHVibGljLWtleQ=="
	sig := base64.StdEncoding.EncodeToString(ed25519.Sign(caPriv, CABindingMessage(keyID, pubKey, fromDID)))
	if err := VerifyCABinding(caPub, keyID, pubKey, toDID, sig); !errors.Is(err, ErrCASig) {
		t.Fatalf("binding a key to a different DID than the CA signed must be rejected, got %v", err)
	}
}
