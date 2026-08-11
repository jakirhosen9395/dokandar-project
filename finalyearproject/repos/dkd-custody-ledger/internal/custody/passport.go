package custody

import (
	"crypto/rand"
	"fmt"
	"regexp"
	"strings"
	"time"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

// ProductPassport (root ID: PPID) — event-sourced custody state. One PPID is one indivisible
// lot (C2): quantity is immutable; partial movement requires Split, then Transfer of a child.
type Status string

const (
	StatusActive   Status = "ACTIVE"
	StatusSplit    Status = "SPLIT"    // terminal
	StatusMerged   Status = "MERGED"   // terminal
	StatusRecalled Status = "RECALLED" // terminal
	StatusExpired  Status = "EXPIRED"  // terminal
)

type Role string

const (
	RoleProducer   Role = "PRODUCER"
	RoleAggregator Role = "AGGREGATOR"
	RoleProcessor  Role = "PROCESSOR"
	RoleTrader     Role = "TRADER"
	RoleRetailer   Role = "RETAILER"
	RoleConsumer   Role = "CONSUMER"
	RoleRegulator  Role = "REGULATOR"
)

var validRoles = map[Role]bool{RoleProducer: true, RoleAggregator: true, RoleProcessor: true,
	RoleTrader: true, RoleRetailer: true, RoleConsumer: true, RoleRegulator: true}

const SigningModeCustodial = "CUSTODIAL_SIGNED"

type Passport struct {
	PPID          string
	GPID          string
	CurrentHolder string
	HolderRole    Role
	Quantity      int64 // immutable after init (C2)
	Unit          string
	Status        Status
	Sequence      int64  // last applied sequence in this PPID's chain
	HeadHash      string // eventHash of the chain head
}

// Event is a sealed ledger fact ready for the atomic append (chain rows + outbox in one tx).
// Fields carries the FULL published payload including eventHash. previousHash semantics:
//   - Initialize: "" (genesis, included)
//   - Transfer/Sign: head of the PPID's chain
//   - Split: head of the PARENT chain; child chains ANCHOR on this event's hash (their next
//     event's previousHash = this eventHash) — decision recorded in the BUILD LOG.
//   - Merge: payload previousHash = head of sources[0] (payload carries ONE value; per-source
//     row linkage keeps each source's own head — NEEDS-INFO reconciliation noted); the new
//     PPID's chain anchors on this event's hash.
//   - ProductRecalled: NO previousHash field at all (batch regulatory event, Spec §6); row-level
//     linkage still records each target's head.
type Event struct {
	Type      string // frozen topic name
	Key       string // ordering key (PPID; exceptions: parentPpid / newPpid / recallId)
	EventID   string
	EventHash string
	Fields    map[string]any
}

var uuid7Re = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)

func uuidv7New() string {
	var b [16]byte
	ms := uint64(time.Now().UnixMilli())
	b[0], b[1], b[2] = byte(ms>>40), byte(ms>>32), byte(ms>>24)
	b[3], b[4], b[5] = byte(ms>>16), byte(ms>>8), byte(ms)
	if _, err := rand.Read(b[6:]); err != nil {
		panic(fmt.Sprintf("uuidv7: entropy unavailable: %v", err))
	}
	b[6] = 0x70 | (b[6] & 0x0f)
	b[8] = 0x80 | (b[8] & 0x3f)
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// NewPPID7 mints PP-{uuid7} (ids.yaml: body is uuid7; SDK validates prefix only, so the body
// check lives here).
func NewPPID7() string { return string(dkd.PPIDPrefix) + uuidv7New() }

func ValidatePPID(s string) error {
	if _, err := dkd.NewPPID(s); err != nil {
		return err
	}
	if !uuid7Re.MatchString(strings.TrimPrefix(s, string(dkd.PPIDPrefix))) {
		return fmt.Errorf("custody: ppid body is not a uuidv7: %q", s)
	}
	return nil
}

func validDID(s string) error {
	if _, err := dkd.NewDID(s); err != nil {
		return fmt.Errorf("custody: invalid DID: %w", err)
	}
	return nil
}

func validRole(r Role) error {
	if !validRoles[r] {
		return fmt.Errorf("custody: invalid custody role %q", r)
	}
	return nil
}

func seal(topic, key string, fields map[string]any) (Event, error) {
	h, err := EventHash(fields)
	if err != nil {
		return Event{}, err
	}
	fields["eventHash"] = h
	return Event{Type: topic, Key: key, EventID: uuidv7New(), EventHash: h, Fields: fields}, nil
}

type InitInput struct {
	GPID       string
	Holder     string
	HolderRole Role
	Quantity   int64
	Unit       string
	ProducedAt int64
}

// InitializeCustody mints the PPID and seals the genesis event (previousHash "").
// The GPID-must-be-PUBLISHED precondition is enforced by the caller via the Catalog client
// (R7 master-data conformance); quantity/unit/holder are validated here.
func InitializeCustody(in InitInput, nowMs int64) (*Passport, Event, error) {
	if _, err := dkd.NewGPID(in.GPID); err != nil {
		return nil, Event{}, fmt.Errorf("custody: invalid GPID: %w", err)
	}
	if err := validDID(in.Holder); err != nil {
		return nil, Event{}, err
	}
	if err := validRole(in.HolderRole); err != nil {
		return nil, Event{}, err
	}
	if in.Quantity <= 0 {
		return nil, Event{}, fmt.Errorf("custody: quantity must be positive")
	}
	if strings.TrimSpace(in.Unit) == "" {
		return nil, Event{}, fmt.Errorf("custody: unit is required")
	}
	if in.ProducedAt <= 0 {
		return nil, Event{}, fmt.Errorf("custody: producedAt (unix-ms) is required")
	}
	p := &Passport{
		PPID: NewPPID7(), GPID: in.GPID, CurrentHolder: in.Holder, HolderRole: in.HolderRole,
		Quantity: in.Quantity, Unit: in.Unit, Status: StatusActive, Sequence: 1,
	}
	ev, err := seal(dkd.TopicCustodyPassportCustodyInitializedV1, p.PPID, map[string]any{
		"ppid": p.PPID, "gpid": p.GPID, "holder": p.CurrentHolder, "holderRole": string(p.HolderRole),
		"quantity": p.Quantity, "unit": p.Unit, "producedAt": in.ProducedAt,
		"initializedAt": nowMs, "previousHash": "",
	})
	if err != nil {
		return nil, Event{}, err
	}
	p.HeadHash = ev.EventHash
	return p, ev, nil
}

func (p *Passport) requireActive(op string) error {
	if p.Status != StatusActive {
		return fmt.Errorf("custody: %s is only legal on ACTIVE passports (status=%s)", op, p.Status)
	}
	return nil
}

// TransferSig is the verified dual-signature envelope handed to the aggregate by the application
// layer AFTER both cryptographic checks pass (BR-005/FR-PASS-010: the RELEASING custodian
// `fromHolder`=actor_did AND the RECEIVING custodian `toHolder`=cosign_did each produce a valid
// Ed25519 signature over the transfer event's eventHash, each key bound to the party it signs
// for). The pure domain cannot reach the DB signer-key registry, so verification lives in
// internal/signing; here the aggregate only attaches the sealed envelope. FromSignature and
// ToSignature are base64-std Ed25519 signatures over the 64-char eventHash hex string. The
// envelope is persisted but EXCLUDED from the chain hash (see envelopeExcluded — reuses the same
// signature/keyId/coSignature/coKeyId slots the CustodialSigned event uses, so no new exclusion
// entry and the transfer digest is byte-identical to the pre-signature form for existing chains).
type TransferSig struct {
	FromKeyID     string // releasing custodian (actor_did = fromHolder) signing-key reference
	FromSignature string // Ed25519 by fromHolder's key over eventHash
	ToKeyID       string // receiving custodian (cosign_did = toHolder) signing-key reference
	ToSignature   string // Ed25519 by toHolder's key over the SAME eventHash
	// AttestationSignature (C3-F2e) is set INSTEAD of the dual holder signatures for a
	// saga-internal, reference-linked move (e.g. a logistics POD): a SINGLE base64-std Ed25519
	// signature by the trusted attestation authority over the POD-ATTEST message (NOT the
	// eventHash). It is verified in internal/signing.VerifyAttestation BEFORE this call; here the
	// aggregate only seals it into the excluded envelope. Empty for human dual-signed transfers.
	AttestationSignature string
}

// TransferSemanticFields returns the EXACT canonical payload that both the sealed eventHash and
// the two Ed25519 signatures are computed over (BR-005: "over identical canonical bytes"). The
// signature/keyref envelope is deliberately absent (EventHash excludes it): defining the signed
// content in ONE place guarantees the hash the client signs, the hash internal/signing recomputes,
// and the hash seal() stores are identical. quantity/unit/gpid/previousHash are SERVER-derived
// (C2 full-transfer, never caller-supplied); the caller passes the loaded passport's values.
func TransferSemanticFields(ppid, gpid, fromHolder, toHolder string, toRole Role, quantity int64, unit string, transferredAt int64, previousHash, referenceOrd string) map[string]any {
	fields := map[string]any{
		"ppid": ppid, "gpid": gpid, "fromHolder": fromHolder, "toHolder": toHolder,
		"toHolderRole": string(toRole), "quantity": quantity, "unit": unit,
		"transferredAt": transferredAt, "previousHash": previousHash,
	}
	if referenceOrd != "" {
		fields["referenceOrd"] = referenceOrd
	}
	return fields
}

// Transfer moves the WHOLE lot (quantity derived, never caller-supplied — C2). BR-005/FR-PASS-010:
// custody MUST NOT move without a valid dual signature (releasing + receiving custodian) over the
// transfer event's canonical bytes. Cryptographic verification of `sig` is performed by the
// application layer (internal/signing.VerifyTransfer) BEFORE this call; here the aggregate
// re-enforces its state-machine invariants, seals the event over the SEMANTIC fields, and attaches
// the verified envelope (excluded from the hash). transferredAt is client-supplied so the two
// parties can precompute the exact eventHash they sign.
func (p *Passport) Transfer(fromHolder, toHolder string, toRole Role, referenceOrd string, transferredAt int64, sig TransferSig) (Event, error) {
	if err := p.requireActive("TransferCustody"); err != nil {
		return Event{}, err
	}
	if fromHolder != p.CurrentHolder {
		return Event{}, fmt.Errorf("custody: fromHolder is not the current holder")
	}
	if err := validDID(toHolder); err != nil {
		return Event{}, err
	}
	if err := validRole(toRole); err != nil {
		return Event{}, err
	}
	if transferredAt <= 0 {
		return Event{}, fmt.Errorf("custody: transferredAt (unix-ms) is required")
	}
	fields := TransferSemanticFields(p.PPID, p.GPID, fromHolder, toHolder, toRole, p.Quantity, p.Unit, transferredAt, p.HeadHash, referenceOrd)
	// Crypto envelope — persisted in the JSONB payload but excluded from the chain hash. The
	// releasing custodian occupies the keyId/signature slot; the receiving custodian occupies
	// coKeyId/coSignature — the SAME excluded slots the CustodialSigned event uses.
	fields["keyId"] = sig.FromKeyID
	fields["signature"] = sig.FromSignature
	fields["coKeyId"] = sig.ToKeyID
	fields["coSignature"] = sig.ToSignature
	// C3-F2e: a reference-linked attestation move carries the authority signature INSTEAD of the
	// dual holder signatures. Persist it in the (already-excluded) envelope; absent for human
	// dual-signed transfers, so those events' canonical bytes are byte-for-byte unchanged.
	if sig.AttestationSignature != "" {
		fields["attestationSignature"] = sig.AttestationSignature
	}
	ev, err := seal(dkd.TopicCustodyPassportCustodyTransferredV1, p.PPID, fields)
	if err != nil {
		return Event{}, err
	}
	p.CurrentHolder, p.HolderRole = toHolder, toRole
	p.Sequence++
	p.HeadHash = ev.EventHash
	return ev, nil
}

type Alloc struct {
	Holder     string
	HolderRole Role
	Quantity   int64
}

// Split conserves quantity exactly: sum(allocations) == parent quantity; parent becomes
// terminal SPLIT; children are minted ACTIVE with their chains anchored on this event.
func (p *Passport) Split(allocs []Alloc, nowMs int64) (Event, []*Passport, error) {
	if err := p.requireActive("SplitCustody"); err != nil {
		return Event{}, nil, err
	}
	if len(allocs) < 2 {
		return Event{}, nil, fmt.Errorf("custody: split requires at least 2 allocations")
	}
	var sum int64
	children := make([]*Passport, 0, len(allocs))
	allocFields := make([]any, 0, len(allocs))
	for _, a := range allocs {
		if a.Quantity <= 0 {
			return Event{}, nil, fmt.Errorf("custody: allocation quantities must be positive")
		}
		if err := validDID(a.Holder); err != nil {
			return Event{}, nil, err
		}
		if err := validRole(a.HolderRole); err != nil {
			return Event{}, nil, err
		}
		sum += a.Quantity
		child := &Passport{
			PPID: NewPPID7(), GPID: p.GPID, CurrentHolder: a.Holder, HolderRole: a.HolderRole,
			Quantity: a.Quantity, Unit: p.Unit, Status: StatusActive, Sequence: 1,
		}
		children = append(children, child)
		allocFields = append(allocFields, map[string]any{
			"ppid": child.PPID, "holder": a.Holder, "holderRole": string(a.HolderRole), "quantity": a.Quantity,
		})
	}
	if sum != p.Quantity {
		return Event{}, nil, fmt.Errorf("custody: conservation violated: allocations sum %d != quantity %d", sum, p.Quantity)
	}
	ev, err := seal(dkd.TopicCustodyPassportCustodySplitV1, p.PPID /* key = parentPpid */, map[string]any{
		"parentPpid": p.PPID, "gpid": p.GPID, "allocations": allocFields,
		"totalQuantity": p.Quantity, "unit": p.Unit, "splitAt": nowMs, "previousHash": p.HeadHash,
	})
	if err != nil {
		return Event{}, nil, err
	}
	p.Status = StatusSplit
	p.Sequence++
	p.HeadHash = ev.EventHash
	for _, c := range children {
		c.HeadHash = ev.EventHash // child chains anchor on the split event
	}
	return ev, children, nil
}

// Merge combines same-GPID ACTIVE lots into one new PPID; sources become terminal MERGED.
func Merge(sources []*Passport, toHolder string, toRole Role, nowMs int64) (Event, *Passport, error) {
	if len(sources) < 2 {
		return Event{}, nil, fmt.Errorf("custody: merge requires at least 2 sources")
	}
	gpid, unit, holder := sources[0].GPID, sources[0].Unit, sources[0].CurrentHolder
	var total int64
	ppids := make([]any, 0, len(sources))
	for _, s := range sources {
		if err := s.requireActive("MergeCustody"); err != nil {
			return Event{}, nil, err
		}
		if s.GPID != gpid {
			return Event{}, nil, fmt.Errorf("custody: merge sources must share one GPID")
		}
		if s.Unit != unit {
			return Event{}, nil, fmt.Errorf("custody: merge sources must share one unit")
		}
		// C3-F4 (M4): all sources must be held by ONE holder (caller-owns-all) — you cannot merge
		// passports held by different parties into one lot.
		if s.CurrentHolder != holder {
			return Event{}, nil, fmt.Errorf("custody: merge sources must all be held by a single holder (M4)")
		}
		total += s.Quantity
		ppids = append(ppids, s.PPID)
	}
	if err := validDID(toHolder); err != nil {
		return Event{}, nil, err
	}
	if err := validRole(toRole); err != nil {
		return Event{}, nil, err
	}
	newP := &Passport{
		PPID: NewPPID7(), GPID: gpid, CurrentHolder: toHolder, HolderRole: toRole,
		Quantity: total, Unit: unit, Status: StatusActive, Sequence: 1,
	}
	ev, err := seal(dkd.TopicCustodyPassportCustodyMergedV1, newP.PPID /* key = newPpid */, map[string]any{
		"sourcePpids": ppids, "newPpid": newP.PPID, "totalQuantity": total, "unit": unit,
		"toHolder": toHolder, "toHolderRole": string(toRole), "gpid": gpid, "mergedAt": nowMs,
		"previousHash": sources[0].HeadHash,
	})
	if err != nil {
		return Event{}, nil, err
	}
	for _, s := range sources {
		s.Status = StatusMerged
		s.Sequence++
		s.HeadHash = ev.EventHash
	}
	newP.HeadHash = ev.EventHash
	return ev, newP, nil
}

// RecallProducts seals the batch regulatory event (recallId key, NO previousHash — Spec §6).
// All targets must be ACTIVE and share the payload's single GPID; they become terminal RECALLED.
// recallId is an opaque non-empty token (format NEEDS-INFO in ids.yaml — nothing invented).
func RecallProducts(targets []*Passport, recallID, reason, issuedBy string, nowMs int64) (Event, error) {
	if strings.TrimSpace(recallID) == "" || len(recallID) > 64 {
		return Event{}, fmt.Errorf("custody: recallId must be a non-empty token (<=64 chars)")
	}
	if strings.TrimSpace(reason) == "" {
		return Event{}, fmt.Errorf("custody: recall reason is required")
	}
	if err := validDID(issuedBy); err != nil {
		return Event{}, err
	}
	if len(targets) == 0 {
		return Event{}, fmt.Errorf("custody: recall requires at least one target passport")
	}
	gpid := targets[0].GPID
	ppids := make([]any, 0, len(targets))
	for _, t := range targets {
		if err := t.requireActive("RecallProduct"); err != nil {
			return Event{}, err
		}
		if t.GPID != gpid {
			return Event{}, fmt.Errorf("custody: one recall event covers one GPID (got %s and %s)", gpid, t.GPID)
		}
		ppids = append(ppids, t.PPID)
	}
	ev, err := seal(dkd.TopicCustodyPassportProductRecalledV1, recallID, map[string]any{
		"ppids": ppids, "recallId": recallID, "gpid": gpid, "reason": reason,
		"issuedBy": issuedBy, "recalledAt": nowMs,
	})
	if err != nil {
		return Event{}, err
	}
	for _, t := range targets {
		t.Status = StatusRecalled
		t.Sequence++
		// row-level linkage keeps each target's own head; payload has no previousHash
		t.HeadHash = ev.EventHash
	}
	return ev, nil
}

// CustodialSig is the verified dual-signature envelope handed to the aggregate by the
// application layer AFTER all cryptographic checks pass (Ed25519 verification of both
// signatures over the event hash, key_id↔DID registry binding, four-eyes). The pure domain
// cannot reach the DB signer-key registry, so verification lives in internal/signing; here the
// aggregate only re-enforces its invariants and seals. Signature/CoSignature are base64-std
// Ed25519 signatures over the 64-char eventHash hex string.
type CustodialSig struct {
	AgentDid    string
	KeyID       string
	Signature   string
	CoSignerDid string
	CoKeyID     string
	CoSignature string
	SignedAt    int64
}

// CustodialSemanticFields returns the EXACT payload that both the sealed eventHash and the two
// Ed25519 signatures are computed over. The signature/keyref envelope is deliberately absent
// (EventHash excludes it): defining the signed content in one place guarantees the hash the
// client signs, the hash internal/signing recomputes, and the hash seal() stores are identical.
func CustodialSemanticFields(ppid, agentDid, coSignerDid, previousHash string, signedAt int64) map[string]any {
	return map[string]any{
		"ppid": ppid, "agentDid": agentDid, "signingMode": SigningModeCustodial,
		"signedAt": signedAt, "previousHash": previousHash, "coSignerDid": coSignerDid,
	}
}

// SealCustodialSigned appends a REAL dual-signed custodial co-signature fact; status stays
// ACTIVE (R4/BR-005 four-eyes). Cryptographic verification is performed by the application
// layer (internal/signing) BEFORE this call — see CustodialSig. The sealed eventHash is
// computed over the SEMANTIC fields only (the signature/keyref envelope is excluded by
// EventHash), so it equals the hash the two signatures signed and the persisted signatures
// verify against the stored/recomputed chain hash.
func (p *Passport) SealCustodialSigned(sig CustodialSig) (Event, error) {
	if err := p.requireActive("SignCustodial"); err != nil {
		return Event{}, err
	}
	if err := validDID(sig.AgentDid); err != nil {
		return Event{}, err
	}
	if err := validDID(sig.CoSignerDid); err != nil {
		return Event{}, err
	}
	if sig.CoSignerDid == sig.AgentDid {
		return Event{}, fmt.Errorf("custody: four-eyes violated: co-signer must differ from the acting agent (R4/BR-005)")
	}
	if sig.SignedAt <= 0 {
		return Event{}, fmt.Errorf("custody: signedAt (unix-ms) is required")
	}
	fields := CustodialSemanticFields(p.PPID, sig.AgentDid, sig.CoSignerDid, p.HeadHash, sig.SignedAt)
	// Crypto envelope — persisted in the JSONB payload but excluded from the chain hash:
	fields["keyId"] = sig.KeyID
	fields["signature"] = sig.Signature
	fields["coKeyId"] = sig.CoKeyID
	fields["coSignature"] = sig.CoSignature
	ev, err := seal(dkd.TopicCustodyPassportCustodialSignedV1, p.PPID, fields)
	if err != nil {
		return Event{}, err
	}
	p.Sequence++
	p.HeadHash = ev.EventHash
	return ev, nil
}
