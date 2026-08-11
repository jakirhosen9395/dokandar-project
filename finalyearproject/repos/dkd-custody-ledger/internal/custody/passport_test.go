package custody

import (
	"strings"
	"testing"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

const (
	tGPID   = "GP-rice-0198c0de-0000-7000-8000-000000000001"
	tHolder = "did:dokandar:0198c0de-0000-7000-8000-000000000001"
	tOther  = "did:dokandar:0198c0de-0000-7000-8000-000000000002"
	tNow    = int64(1750000002000)
)

func initPassport(t *testing.T) (*Passport, Event) {
	t.Helper()
	p, ev, err := InitializeCustody(InitInput{
		GPID: tGPID, Holder: tHolder, HolderRole: RoleProducer,
		Quantity: 5000, Unit: "kg", ProducedAt: 1750000000000,
	}, tNow)
	if err != nil {
		t.Fatal(err)
	}
	return p, ev
}

func TestInitializeCustodyGenesis(t *testing.T) {
	p, ev := initPassport(t)
	if err := ValidatePPID(p.PPID); err != nil {
		t.Fatalf("minted ppid invalid: %v", err)
	}
	if p.Status != StatusActive || p.Quantity != 5000 || p.Sequence != 1 {
		t.Fatalf("state: %+v", p)
	}
	if ev.Type != dkd.TopicCustodyPassportCustodyInitializedV1 || ev.Key != p.PPID {
		t.Fatalf("event: %s key=%s", ev.Type, ev.Key)
	}
	if ev.Fields["previousHash"] != "" {
		t.Fatal("genesis previousHash must be the included empty string")
	}
	if ev.EventHash != p.HeadHash || len(ev.EventHash) != 64 {
		t.Fatal("head must be the genesis eventHash")
	}
	ok, err := VerifyEvent(ev.Fields)
	if err != nil || !ok {
		t.Fatalf("sealed event must verify: %v %v", ok, err)
	}
}

func TestInitializeValidation(t *testing.T) {
	base := InitInput{GPID: tGPID, Holder: tHolder, HolderRole: RoleProducer, Quantity: 1, Unit: "kg", ProducedAt: 1}
	bad := base
	bad.Quantity = 0
	if _, _, err := InitializeCustody(bad, tNow); err == nil {
		t.Fatal("zero quantity must fail")
	}
	bad = base
	bad.HolderRole = "FARMER"
	if _, _, err := InitializeCustody(bad, tNow); err == nil {
		t.Fatal("unknown role must fail")
	}
	bad = base
	bad.Holder = "not-a-did"
	if _, _, err := InitializeCustody(bad, tNow); err == nil {
		t.Fatal("bad DID must fail")
	}
}

// dummySig is a placeholder envelope for domain state-machine tests: the pure aggregate attaches
// the envelope opaquely and does NOT verify it (verification is the app layer's job), so these
// tests exercise chaining/state independent of crypto.
var dummySig = TransferSig{FromKeyID: "key-from", FromSignature: "c2ln", ToKeyID: "key-to", ToSignature: "Y29zaWc="}

// The chain: transfer.previousHash == genesis eventHash; head advances.
func TestTransferChainsAndDerivesQuantity(t *testing.T) {
	p, genesis := initPassport(t)
	ev, err := p.Transfer(tHolder, tOther, RoleTrader, "ORD-x", tNow+1, dummySig)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Fields["previousHash"] != genesis.EventHash {
		t.Fatal("transfer must chain to the genesis hash")
	}
	if ev.Fields["quantity"] != p.Quantity || ev.Fields["unit"] != "kg" {
		t.Fatal("quantity/unit are DERIVED (C2 full transfer)")
	}
	if p.CurrentHolder != tOther || p.Status != StatusActive || p.Sequence != 2 {
		t.Fatalf("state after transfer: %+v", p)
	}
	if _, err := p.Transfer(tHolder, tOther, RoleTrader, "", tNow+2, dummySig); err == nil {
		t.Fatal("stale fromHolder must be rejected")
	}
}

// The dual-signature envelope (releasing keyId/signature + receiving coKeyId/coSignature) is
// persisted on the CustodyTransferred event but EXCLUDED from the chain hash: the sealed event
// self-verifies, and the eventHash equals the hash over the SEMANTIC fields only (identical bytes
// to the pre-signature transfer form — backward-compat / determinism).
func TestTransferEnvelopePersistedButExcludedFromHash(t *testing.T) {
	p, _ := initPassport(t)
	ev, err := p.Transfer(tHolder, tOther, RoleTrader, "ORD-x", tNow+1, dummySig)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Fields["keyId"] != "key-from" || ev.Fields["signature"] != "c2ln" ||
		ev.Fields["coKeyId"] != "key-to" || ev.Fields["coSignature"] != "Y29zaWc=" {
		t.Fatalf("envelope must be persisted in the payload: %+v", ev.Fields)
	}
	if ok, err := VerifyEvent(ev.Fields); err != nil || !ok {
		t.Fatalf("sealed transfer must self-verify (envelope excluded): ok=%v err=%v", ok, err)
	}
	// The sealed hash must equal the hash over the SEMANTIC fields alone (envelope-free) — proving
	// the two signatures sign a hash equal to the stored chain hash, over BR-005 canonical bytes.
	semantic := TransferSemanticFields(p.PPID, p.GPID, tHolder, tOther, RoleTrader, p.Quantity, p.Unit, tNow+1, ev.Fields["previousHash"].(string), "ORD-x")
	semHash, err := EventHash(semantic)
	if err != nil {
		t.Fatal(err)
	}
	if semHash != ev.EventHash {
		t.Fatalf("sealed hash must equal the semantic-fields hash: sealed=%s semantic=%s", ev.EventHash, semHash)
	}
	// transferredAt is required (client-supplied, part of the signed bytes).
	q, _ := initPassport(t)
	if _, err := q.Transfer(tHolder, tOther, RoleTrader, "", 0, dummySig); err == nil {
		t.Fatal("missing transferredAt must be rejected")
	}
}

// C3-F2e: an attestation-authority transfer persists a single attestationSignature in the
// envelope, and — because that field is excluded from the hash — the sealed eventHash equals the
// hash over the SEMANTIC fields alone (envelope-free), exactly as the human dual-signed transfer
// does. This proves the attestation path introduces NO new hashed field and cannot alter the chain
// digest (TV-01 determinism), while still self-verifying.
func TestAttestationTransferEnvelopeExcludedFromHash(t *testing.T) {
	p, _ := initPassport(t)
	prev := p.HeadHash
	ev, err := p.Transfer(tHolder, tOther, RoleTrader, "ORD-x", tNow+1,
		TransferSig{AttestationSignature: "YXR0ZXN0LXNpZw=="})
	if err != nil {
		t.Fatal(err)
	}
	// The single attestation signature is persisted in the (excluded) envelope; the human dual-sig
	// slots stay empty, so an attestation move is distinguishable in the payload.
	if ev.Fields["attestationSignature"] != "YXR0ZXN0LXNpZw==" {
		t.Fatalf("attestation signature must be persisted in the payload: %+v", ev.Fields)
	}
	if ev.Fields["signature"] != "" || ev.Fields["coSignature"] != "" {
		t.Fatalf("attestation transfer must not carry human dual-sig values: %+v", ev.Fields)
	}
	if ok, err := VerifyEvent(ev.Fields); err != nil || !ok {
		t.Fatalf("sealed attestation transfer must self-verify (envelope excluded): ok=%v err=%v", ok, err)
	}
	// The sealed hash must equal the hash over the semantic fields alone — i.e. the attestation
	// signature (like the human dual-sig envelope) is excluded and changes no digest.
	semantic := TransferSemanticFields(p.PPID, p.GPID, tHolder, tOther, RoleTrader, p.Quantity, p.Unit, tNow+1, prev, "ORD-x")
	semHash, err := EventHash(semantic)
	if err != nil {
		t.Fatal(err)
	}
	if semHash != ev.EventHash {
		t.Fatalf("sealed attestation hash must equal the semantic-fields hash (envelope excluded): sealed=%s semantic=%s", ev.EventHash, semHash)
	}
}

func TestSplitConservationAndAnchoring(t *testing.T) {
	p, _ := initPassport(t)
	if _, _, err := p.Split([]Alloc{{tHolder, RoleTrader, 4000}, {tOther, RoleTrader, 999}}, tNow); err == nil {
		t.Fatal("conservation violation must fail")
	}
	ev, children, err := p.Split([]Alloc{{tHolder, RoleTrader, 4000}, {tOther, RoleTrader, 1000}}, tNow)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Key != ev.Fields["parentPpid"] {
		t.Fatal("split ordering key must be parentPpid")
	}
	if p.Status != StatusSplit {
		t.Fatal("parent must be terminal SPLIT")
	}
	if len(children) != 2 || children[0].Quantity != 4000 || children[1].Quantity != 1000 {
		t.Fatalf("children: %+v", children)
	}
	for _, c := range children {
		if c.Status != StatusActive || c.HeadHash != ev.EventHash {
			t.Fatal("children must be ACTIVE and anchored on the split event hash")
		}
	}
	// terminal: no further commands on the parent
	if _, err := p.Transfer(tHolder, tOther, RoleTrader, "", tNow, dummySig); err == nil {
		t.Fatal("SPLIT passport must reject transfer")
	}
	// child chains continue from the anchor
	child := children[0]
	tev, err := child.Transfer(tHolder, tOther, RoleRetailer, "", tNow+5, dummySig)
	if err != nil {
		t.Fatal(err)
	}
	if tev.Fields["previousHash"] != ev.EventHash {
		t.Fatal("child's first event must chain to the split hash")
	}
}

func TestMergeSameGPIDOnly(t *testing.T) {
	a, _ := initPassport(t)
	b, _ := initPassport(t)
	ev, merged, err := Merge([]*Passport{a, b}, tOther, RoleAggregator, tNow)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Key != merged.PPID || ev.Fields["newPpid"] != merged.PPID {
		t.Fatal("merge ordering key must be newPpid")
	}
	if merged.Quantity != 10000 || merged.Status != StatusActive {
		t.Fatalf("merged: %+v", merged)
	}
	if a.Status != StatusMerged || b.Status != StatusMerged {
		t.Fatal("sources must be terminal MERGED")
	}
	// different GPID rejected
	c, _ := initPassport(t)
	d, _, err2 := InitializeCustody(InitInput{GPID: "GP-jute-0198c0de-0000-7000-8000-000000000009",
		Holder: tHolder, HolderRole: RoleProducer, Quantity: 1, Unit: "kg", ProducedAt: 1}, tNow)
	if err2 != nil {
		t.Fatal(err2)
	}
	if _, _, err := Merge([]*Passport{c, d}, tOther, RoleAggregator, tNow); err == nil {
		t.Fatal("cross-GPID merge must fail")
	}
}

// C3-F4 (M4): merge sources held by DIFFERENT holders must be rejected (caller-owns-all).
func TestMergeRejectsMultiHolder(t *testing.T) {
	a, _ := initPassport(t) // held by tHolder
	b, _, err := InitializeCustody(InitInput{GPID: tGPID, Holder: tOther, HolderRole: RoleProducer,
		Quantity: 5000, Unit: "kg", ProducedAt: 1750000000000}, tNow) // same GPID/unit, held by tOther
	if err != nil {
		t.Fatal(err)
	}
	if _, _, err := Merge([]*Passport{a, b}, tOther, RoleAggregator, tNow); err == nil {
		t.Fatal("merge of sources held by different holders must fail (M4)")
	}
	// sanity: two sources with the SAME holder still merge cleanly
	c, _ := initPassport(t)
	d, _ := initPassport(t)
	if _, _, err := Merge([]*Passport{c, d}, tOther, RoleAggregator, tNow); err != nil {
		t.Fatalf("same-holder merge must still succeed: %v", err)
	}
}

// ProductRecalled: recallId key, NO previousHash field, targets terminal RECALLED.
func TestRecallBatchSemantics(t *testing.T) {
	a, _ := initPassport(t)
	b, _ := initPassport(t)
	ev, err := RecallProducts([]*Passport{a, b}, "rcl-2026-001", "contamination", tHolder, tNow)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Type != dkd.TopicCustodyPassportProductRecalledV1 || ev.Key != "rcl-2026-001" {
		t.Fatalf("recall event: %s key=%s", ev.Type, ev.Key)
	}
	if _, has := ev.Fields["previousHash"]; has {
		t.Fatal("ProductRecalled must NOT carry previousHash (Spec §6 batch event)")
	}
	ok, err := VerifyEvent(ev.Fields)
	if err != nil || !ok {
		t.Fatal("recall event must self-verify")
	}
	if a.Status != StatusRecalled || b.Status != StatusRecalled {
		t.Fatal("targets must be terminal RECALLED")
	}
	if _, err := a.Transfer(tHolder, tOther, RoleTrader, "", tNow, dummySig); err == nil {
		t.Fatal("RECALLED passport must reject transfer")
	}
	if _, err := RecallProducts([]*Passport{a}, "rcl-2", "again", tHolder, tNow); err == nil {
		t.Fatal("recalling a RECALLED passport must fail")
	}
}

func TestSealCustodialSignedKeepsActive(t *testing.T) {
	p, genesis := initPassport(t)
	sig := CustodialSig{
		AgentDid: tHolder, KeyID: "key-agent-1", Signature: "c2lnbmF0dXJl",
		CoSignerDid: tOther, CoKeyID: "key-co-1", CoSignature: "Y29zaWduYXR1cmU=",
		SignedAt: tNow,
	}
	ev, err := p.SealCustodialSigned(sig)
	if err != nil {
		t.Fatal(err)
	}
	if ev.Fields["signingMode"] != SigningModeCustodial {
		t.Fatal("signingMode must be CUSTODIAL_SIGNED")
	}
	if ev.Fields["coSignerDid"] != tOther {
		t.Fatal("coSignerDid (semantic) must be carried in the payload")
	}
	if ev.Fields["signature"] != "c2lnbmF0dXJl" || ev.Fields["coSignature"] != "Y29zaWduYXR1cmU=" {
		t.Fatal("signature envelope must be persisted in the payload")
	}
	if ev.Fields["previousHash"] != genesis.EventHash {
		t.Fatal("sign must chain to head")
	}
	if p.Status != StatusActive || p.Sequence != 2 || p.HeadHash != ev.EventHash {
		t.Fatalf("sign must keep ACTIVE and advance the head: %+v", p)
	}
	// The sealed eventHash must self-verify (recompute over semantic fields, envelope excluded).
	if ok, err := VerifyEvent(ev.Fields); err != nil || !ok {
		t.Fatalf("sealed CustodialSigned event must self-verify: ok=%v err=%v", ok, err)
	}
	// Four-eyes (R4/BR-005): co-signer must differ from the acting agent.
	same := sig
	same.CoSignerDid = same.AgentDid
	if _, err := p.SealCustodialSigned(same); err == nil {
		t.Fatal("four-eyes: identical agent and co-signer must be rejected")
	}
	// signedAt is required.
	noTime := sig
	noTime.SignedAt = 0
	if _, err := p.SealCustodialSigned(noTime); err == nil {
		t.Fatal("missing signedAt must be rejected")
	}
}

func TestNoPIIInPayloads(t *testing.T) {
	p, ev := initPassport(t)
	tev, _ := p.Transfer(tHolder, tOther, RoleTrader, "", tNow, dummySig)
	for _, e := range []Event{ev, tev} {
		for k := range e.Fields {
			lk := strings.ToLower(k)
			for _, banned := range []string{"phone", "name", "address", "nid", "email"} {
				if strings.Contains(lk, banned) {
					t.Fatalf("PII-shaped field %q in %s payload (C1)", k, e.Type)
				}
			}
		}
	}
}
