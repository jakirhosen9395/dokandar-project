// Package signing is custody-ledger-svc's application-layer verifier for the REAL Ed25519 dual
// custodial co-signature (C3-F2). It replaces the fingerprint-length stub: BOTH the acting
// agent and a DISTINCT co-signer must produce a valid Ed25519 signature over the event hash,
// each signing key must be registered and BOUND to the DID it signs for, and the co-signer must
// differ from the agent (R4/BR-005 four-eyes). The pure custody aggregate cannot reach the DB
// key registry, so this verification lives here; the aggregate only seals the verified fact.
package signing

import (
	"crypto/ed25519"
	"encoding/base64"
	"errors"
	"strconv"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/custody"
)

var (
	// ErrSameSigner — four-eyes: the co-signer DID must differ from the acting agent DID.
	ErrSameSigner = errors.New("signing: four-eyes violated: co-signer must differ from the acting agent (R4/BR-005)")
	// ErrAgentBinding — the agent's keyId is not bound to the acting agentDid in the registry.
	ErrAgentBinding = errors.New("signing: agent keyId is not bound to the acting agentDid")
	// ErrCoSignerBinding — the co-signer's coKeyId is not bound to the coSignerDid in the registry.
	ErrCoSignerBinding = errors.New("signing: co-signer coKeyId is not bound to the coSignerDid")
	// ErrAgentSig — the agent Ed25519 signature does not verify over the recomputed event hash.
	ErrAgentSig = errors.New("signing: agent Ed25519 signature does not verify over the event hash")
	// ErrCoSig — the co-signer Ed25519 signature does not verify over the recomputed event hash.
	ErrCoSig = errors.New("signing: co-signer Ed25519 signature does not verify over the event hash")
	// ErrBadSignatureEncoding — a supplied signature is not valid base64-std.
	ErrBadSignatureEncoding = errors.New("signing: signature is not valid base64-std")
	// ErrBadPublicKey — a registered public key is not a base64-std 32-byte Ed25519 key.
	ErrBadPublicKey = errors.New("signing: public key is not a base64-std 32-byte Ed25519 key")

	// --- BR-005/FR-PASS-010: dual-signed CUSTODY_TRANSFER (releasing + receiving custodian) ---

	// ErrFromBinding — the from-holder's fromKeyId is not bound to fromHolder (actor_did).
	ErrFromBinding = errors.New("signing: fromKeyId is not bound to fromHolder (releasing custodian)")
	// ErrToBinding — the to-holder's toKeyId is not bound to toHolder (cosign_did).
	ErrToBinding = errors.New("signing: toKeyId is not bound to toHolder (receiving custodian)")
	// ErrFromSig — the releasing custodian's Ed25519 signature does not verify over the event hash.
	ErrFromSig = errors.New("signing: fromHolder (releasing custodian) Ed25519 signature does not verify over the transfer event hash")
	// ErrToSig — the receiving custodian's Ed25519 signature does not verify over the event hash.
	ErrToSig = errors.New("signing: toHolder (receiving custodian) Ed25519 signature does not verify over the transfer event hash")

	// --- FR-PASS-070 / BR-014: signer-key registration root of trust (CA-signed binding) ---

	// ErrTrustAnchorUnset — the configured trust-anchor (CA) public key is missing: FAIL CLOSED
	// (reject every registration; never fall back to an open endpoint).
	ErrTrustAnchorUnset = errors.New("signing: trust-anchor (CA) public key is not configured — signer-key registration is closed")
	// ErrCASig — the CA signature over the canonical key->DID binding does not verify.
	ErrCASig = errors.New("signing: CA signature over the key->DID binding does not verify against the trust anchor")

	// --- C3-F2e / FR-PASS-014 / FR-PASS-070: attestation-authority (single-sig, reference-linked) ---

	// ErrAttestationAuthorityUnset — the configured attestation-authority public key is missing:
	// FAIL CLOSED (attestation mode is unavailable; never fall open to the human path).
	ErrAttestationAuthorityUnset = errors.New("signing: attestation-authority public key is not configured — attestation mode is unavailable")
	// ErrAttestationSig — the attestation signature does not verify against the configured authority.
	ErrAttestationSig = errors.New("signing: attestation signature does not verify against the configured attestation authority")
)

// AttestationMessage is the EXACT byte string a trusted attestation authority signs to authorize a
// SINGLE-signature, reference-linked custody move (C3-F2e; e.g. a logistics POD — FR-PASS-014
// shipment-linked transfer, FR-PASS-070 server-side authorization for automated/low-tech flows).
// It is a fixed, newline-delimited canonical form the authority (logistics) can compute WITHOUT the
// server's chain state, and which the custody server reconstructs solely from the request path
// (ppid) + body (fromHolder/toHolder/toHolderRole/referenceOrd/transferredAt):
//
//	"POD-ATTEST\n" + ppid + "\n" + fromHolder + "\n" + toHolder + "\n" + toHolderRole + "\n" +
//	    referenceOrd + "\n" + strconv(transferredAt)
//
// The "POD-ATTEST" domain-separation prefix and the mandatory (caller-enforced) non-empty
// referenceOrd scope this signature to reference-linked moves, so an authority signature can NEVER
// stand in for an arbitrary human hand-off. This message is DISTINCT from the transfer eventHash the
// human dual-signature covers — the two authorization paths sign different bytes and never overlap.
func AttestationMessage(ppid, fromHolder, toHolder, toHolderRole, referenceOrd string, transferredAt int64) []byte {
	return []byte("POD-ATTEST\n" + ppid + "\n" + fromHolder + "\n" + toHolder + "\n" +
		toHolderRole + "\n" + referenceOrd + "\n" + strconv.FormatInt(transferredAt, 10))
}

// VerifyAttestation authorizes a reference-linked custody move via a SINGLE attestation signature
// (C3-F2e). FAIL CLOSED: if the authority key is unset (nil/wrong length) it returns
// ErrAttestationAuthorityUnset — attestation mode is unavailable and the caller must NOT fall back
// to the human path. sigB64 is base64-std Ed25519 over AttestationMessage.
func VerifyAttestation(authority ed25519.PublicKey, msg []byte, sigB64 string) error {
	if len(authority) != ed25519.PublicKeySize {
		return ErrAttestationAuthorityUnset
	}
	sig, err := base64.StdEncoding.DecodeString(sigB64)
	if err != nil {
		return ErrBadSignatureEncoding
	}
	if !ed25519.Verify(authority, msg, sig) {
		return ErrAttestationSig
	}
	return nil
}

// ResolvedKey is a signer-key registry entry: the raw Ed25519 public key and the DID it is
// bound to. The registry holds PUBLIC keys only — private keys never leave the signer.
type ResolvedKey struct {
	PublicKey ed25519.PublicKey
	BoundDID  string
}

// Request is a co-sign command with the passport head already fixed (PreviousHash = HeadHash).
// Signature/CoSignature are base64-std Ed25519 signatures over the eventHash hex string.
type Request struct {
	PPID         string
	AgentDid     string
	CoSignerDid  string
	SignedAt     int64
	PreviousHash string
	Signature    string
	CoSignature  string
}

// EventHashHex is the 64-char lowercase-hex digest that BOTH signatures MUST sign. It is
// computed over the custodial SEMANTIC fields (crypto envelope excluded), IDENTICAL to what the
// domain seal() stores — so a verified signature is provably a signature over the persisted
// event's chain hash. Any changed semantic field (agentDid, signedAt, previousHash, coSignerDid,
// ...) changes this digest and therefore invalidates both signatures — that is the tamper guard.
func EventHashHex(r Request) (string, error) {
	return custody.EventHash(custody.CustodialSemanticFields(
		r.PPID, r.AgentDid, r.CoSignerDid, r.PreviousHash, r.SignedAt))
}

// Verify enforces, in order: four-eyes (distinct co-signer), key_id↔DID binding for BOTH keys,
// and Ed25519 verification of BOTH signatures over the recomputed event hash. It returns a
// typed error on the first failure; nil means every check passed. The DID-binding checks make a
// signature from a key that is not bound to the acting DID a rejection even if the raw Ed25519
// math would verify — the key must belong to the party it claims to act for.
func Verify(r Request, agent, co ResolvedKey) error {
	if r.CoSignerDid == r.AgentDid {
		return ErrSameSigner
	}
	if agent.BoundDID != r.AgentDid {
		return ErrAgentBinding
	}
	if co.BoundDID != r.CoSignerDid {
		return ErrCoSignerBinding
	}
	hexHash, err := EventHashHex(r)
	if err != nil {
		return err
	}
	msg := []byte(hexHash)
	agSig, err := base64.StdEncoding.DecodeString(r.Signature)
	if err != nil {
		return ErrBadSignatureEncoding
	}
	if len(agent.PublicKey) != ed25519.PublicKeySize || !ed25519.Verify(agent.PublicKey, msg, agSig) {
		return ErrAgentSig
	}
	coSig, err := base64.StdEncoding.DecodeString(r.CoSignature)
	if err != nil {
		return ErrBadSignatureEncoding
	}
	if len(co.PublicKey) != ed25519.PublicKeySize || !ed25519.Verify(co.PublicKey, msg, coSig) {
		return ErrCoSig
	}
	return nil
}

// DecodePublicKey parses a base64-std 32-byte Ed25519 public key as stored in the registry.
func DecodePublicKey(b64 string) (ed25519.PublicKey, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil || len(raw) != ed25519.PublicKeySize {
		return nil, ErrBadPublicKey
	}
	return ed25519.PublicKey(raw), nil
}

// TransferRequest is a dual-signed CUSTODY_TRANSFER command (C3-F2b(ii); BR-005/FR-PASS-010).
// quantity/unit/gpid/previousHash are the SERVER-derived values of the loaded passport (C2 —
// never trusted from the client); fromHolder/toHolder/toHolderRole/transferredAt/referenceOrd are
// the client-supplied transfer parameters. FromSignature and ToSignature are base64-std Ed25519
// signatures over the eventHash hex string of the transfer's canonical (envelope-free) fields.
type TransferRequest struct {
	PPID          string
	GPID          string
	FromHolder    string
	ToHolder      string
	ToHolderRole  string
	Quantity      int64
	Unit          string
	TransferredAt int64
	PreviousHash  string
	ReferenceOrd  string
	FromSignature string
	ToSignature   string
}

// TransferEventHashHex is the 64-char lowercase-hex digest BOTH transfer signatures MUST sign.
// It is computed over the transfer SEMANTIC fields (crypto envelope excluded), IDENTICAL to what
// the domain seal() stores — so a verified signature is provably a signature over the persisted
// transfer event's chain hash. Any changed field (fromHolder, toHolder, transferredAt,
// previousHash, quantity, ...) changes this digest and invalidates both signatures.
func TransferEventHashHex(r TransferRequest) (string, error) {
	return custody.EventHash(custody.TransferSemanticFields(
		r.PPID, r.GPID, r.FromHolder, r.ToHolder, custody.Role(r.ToHolderRole),
		r.Quantity, r.Unit, r.TransferredAt, r.PreviousHash, r.ReferenceOrd))
}

// VerifyTransfer enforces BR-005/FR-PASS-010 for a CUSTODY_TRANSFER: the RELEASING custodian
// (fromHolder = actor_did) AND the RECEIVING custodian (toHolder = cosign_did) must EACH produce a
// valid Ed25519 signature over the SAME transfer eventHash, with each key bound to the party it
// signs for. It returns a typed error on the first failure; nil means custody may move. An
// unsigned transfer (empty signatures) fails ed25519 verification and is rejected here. The
// DID-binding checks reject a signature from a key not bound to the acting party even if the raw
// Ed25519 math would verify — the key must belong to the custodian it claims to act for.
func VerifyTransfer(r TransferRequest, from, to ResolvedKey) error {
	if from.BoundDID != r.FromHolder {
		return ErrFromBinding
	}
	if to.BoundDID != r.ToHolder {
		return ErrToBinding
	}
	hexHash, err := TransferEventHashHex(r)
	if err != nil {
		return err
	}
	msg := []byte(hexHash)
	fromSig, err := base64.StdEncoding.DecodeString(r.FromSignature)
	if err != nil {
		return ErrBadSignatureEncoding
	}
	if len(from.PublicKey) != ed25519.PublicKeySize || !ed25519.Verify(from.PublicKey, msg, fromSig) {
		return ErrFromSig
	}
	toSig, err := base64.StdEncoding.DecodeString(r.ToSignature)
	if err != nil {
		return ErrBadSignatureEncoding
	}
	if len(to.PublicKey) != ed25519.PublicKeySize || !ed25519.Verify(to.PublicKey, msg, toSig) {
		return ErrToSig
	}
	return nil
}

// CABindingMessage is the EXACT byte string the trust-anchor (CA) signs to authorize a
// key->DID binding (C3-F2c; FR-PASS-070 root of trust). It is the UTF-8 bytes of
// keyId + "\n" + publicKey + "\n" + did — a fixed, unambiguous, newline-delimited canonical form
// (keyId and did are prefixed identifiers that never contain a newline; publicKey is base64-std).
// The same bytes are produced by the proof script's CA signer, so the two agree byte-for-byte.
func CABindingMessage(keyID, publicKey, did string) []byte {
	return []byte(keyID + "\n" + publicKey + "\n" + did)
}

// VerifyCABinding rejects a signer-key registration unless it carries a valid CA signature over
// CABindingMessage, verified against the configured trust anchor. FAIL CLOSED: if the trust
// anchor is unset (nil/wrong length) EVERY registration is rejected — never an open fallback.
// caSigB64 is base64-std Ed25519.
func VerifyCABinding(trustAnchor ed25519.PublicKey, keyID, publicKey, did, caSigB64 string) error {
	if len(trustAnchor) != ed25519.PublicKeySize {
		return ErrTrustAnchorUnset
	}
	sig, err := base64.StdEncoding.DecodeString(caSigB64)
	if err != nil {
		return ErrBadSignatureEncoding
	}
	if !ed25519.Verify(trustAnchor, CABindingMessage(keyID, publicKey, did), sig) {
		return ErrCASig
	}
	return nil
}
