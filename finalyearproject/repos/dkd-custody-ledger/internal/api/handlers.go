// Package api is custody-ledger-svc's external REST /v1 surface: every write carries an
// Idempotency-Key, every response uses the {success,data,error,meta} envelope or RFC-7807
// problem+json (dokandar.custody.* taxonomy, concrete codes provisional).
package api

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"io"
	"net/http"
	"strconv"
	"time"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/custody"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/obs"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/signing"
	"gitlab.com/final-year-project3354127/custody-ledger-svc/internal/store"
)

const (
	MetricCommands = "custody_commands_total"
	MetricReplays  = "custody_idempotent_replays_total"
	maxBodyBytes   = 1 << 20
)

type Store interface {
	Append(ctx context.Context, ev custody.Event, occurredAtMs int64, affected []store.Affected) error
	GetHead(ctx context.Context, ppid string) (*custody.Passport, error)
	ActiveByGPID(ctx context.Context, gpid string, limit int) ([]*custody.Passport, error)
	ListEvents(ctx context.Context, ppid string) ([]store.ChainRow, error)
	VerifyChain(ctx context.Context, ppid string) (bool, string, error)
	GetIdem(ctx context.Context, key string) (int, string, []byte, bool, error)
	PutIdem(ctx context.Context, key, reqHash string, status int, resp []byte) error
	GetSignerKey(ctx context.Context, keyID string) (publicKey, boundDID string, found bool, err error)
	UpsertSignerKey(ctx context.Context, keyID, publicKey, boundDID string, createdAt int64) error
}

type CatalogChecker interface {
	Enabled() bool
	GPIDPublished(ctx context.Context, gpid string) (bool, error)
}

// KycChecker is custody's port to the Identity OHS for the C3-F5 KYC-tier gate.
type KycChecker interface {
	Enabled() bool
	KycTier(ctx context.Context, did string) (string, error)
}

type Metrics interface{ Inc(name string) }

type API struct {
	st       Store
	cat      CatalogChecker
	identity KycChecker
	m        Metrics
	log      *slog.Logger
	now      func() int64
	// trustAnchor is the CA public key authorizing signer-key registrations (C3-F2c). nil ==>
	// registration FAILS CLOSED (the endpoint rejects every binding; never an open fallback).
	trustAnchor ed25519.PublicKey
	// attestationAuthority is the trusted authority public key that authorizes single-signature,
	// reference-linked custody moves (C3-F2e; e.g. a logistics POD). nil ==> attestation mode is
	// UNAVAILABLE (a transfer bearing an attestationSignature is rejected — fail closed).
	attestationAuthority ed25519.PublicKey
}

func New(st Store, cat CatalogChecker, identity KycChecker, m Metrics, log *slog.Logger, now func() int64, trustAnchor, attestationAuthority ed25519.PublicKey) *API {
	return &API{st: st, cat: cat, identity: identity, m: m, log: log, now: now, trustAnchor: trustAnchor, attestationAuthority: attestationAuthority}
}

func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/custody/passports", a.idem(a.initialize))
	mux.HandleFunc("GET /v1/custody/passports/{ppid}", a.getPassport)
	mux.HandleFunc("GET /v1/custody/passports/{ppid}/events", a.listEvents)
	mux.HandleFunc("GET /v1/custody/passports/{ppid}/verify", a.verifyChain)
	mux.HandleFunc("POST /v1/custody/passports/{ppid}/transfer", a.idem(a.transfer))
	mux.HandleFunc("POST /v1/custody/passports/{ppid}/split", a.idem(a.split))
	mux.HandleFunc("POST /v1/custody/merges", a.idem(a.merge))
	mux.HandleFunc("POST /v1/custody/recalls", a.idem(a.recall))
	mux.HandleFunc("POST /v1/custody/passports/{ppid}/sign", a.idem(a.sign))
	// Signer-key registry (C3-F2): PUBLIC keys only, Identity-PKI-fed in prod; this is the dev
	// seed path. Upsert is naturally idempotent, so no Idempotency-Key header is required.
	mux.HandleFunc("POST /v1/custody/signer-keys", a.registerSignerKey)
}

func code(category, reason string) string {
	c, err := dkd.ErrorCode("custody", category, reason)
	if err != nil {
		return "dokandar.custody.internal.bad_code"
	}
	return c
}

func writeJSON(w http.ResponseWriter, status int, ct string, body any) {
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeData(w http.ResponseWriter, status int, data any) {
	writeJSON(w, status, "application/json", map[string]any{"success": true, "data": data, "error": nil})
}

func writeProblem(w http.ResponseWriter, status int, codeStr, title, detail string) {
	writeJSON(w, status, "application/problem+json", map[string]any{
		"type": "about:blank", "title": title, "status": status, "code": codeStr, "detail": detail,
	})
}

type recorder struct {
	http.ResponseWriter
	status int
	buf    bytes.Buffer
}

func (r *recorder) WriteHeader(s int) { r.status = s; r.ResponseWriter.WriteHeader(s) }
func (r *recorder) Write(b []byte) (int, error) {
	r.buf.Write(b)
	return r.ResponseWriter.Write(b)
}

func (a *API) idem(next http.HandlerFunc) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		key := r.Header.Get("Idempotency-Key")
		if key == "" {
			writeProblem(w, http.StatusBadRequest, code("validation", "idempotency_key_required"),
				"Idempotency-Key required", "custody writes must carry an Idempotency-Key header")
			return
		}
		body, err := io.ReadAll(io.LimitReader(r.Body, maxBodyBytes))
		if err != nil {
			writeProblem(w, http.StatusBadRequest, code("validation", "unreadable_body"), "unreadable body", err.Error())
			return
		}
		r.Body = io.NopCloser(bytes.NewReader(body))
		sum := sha256.Sum256(body)
		hash := hex.EncodeToString(sum[:])
		status, storedHash, resp, found, err := a.st.GetIdem(r.Context(), key)
		if err != nil {
			writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "idempotency_store"),
				"idempotency store unavailable", err.Error())
			return
		}
		if found {
			if storedHash != hash {
				writeProblem(w, http.StatusConflict, code("conflict", "idempotency_key_reused"),
					"Idempotency-Key reused", "the key was used with a different request body")
				return
			}
			a.m.Inc(MetricReplays)
			w.Header().Set("Idempotency-Replay", "true")
			w.Header().Set("Content-Type", "application/json")
			w.WriteHeader(status)
			_, _ = w.Write(resp)
			return
		}
		rec := &recorder{ResponseWriter: w, status: http.StatusOK}
		next(rec, r)
		if rec.status < 500 {
			if err := a.st.PutIdem(r.Context(), key, hash, rec.status, rec.buf.Bytes()); err != nil {
				a.log.Warn("idempotency record failed", "err", err)
			}
		}
	}
}

func decode(w http.ResponseWriter, r *http.Request, dst any) bool {
	if err := json.NewDecoder(r.Body).Decode(dst); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_json"), "invalid JSON", err.Error())
		return false
	}
	return true
}

func (a *API) loadActive(w http.ResponseWriter, r *http.Request, ppid string) (*custody.Passport, bool) {
	p, err := a.st.GetHead(r.Context(), ppid)
	if err != nil {
		if errors.Is(err, store.ErrNotFound) {
			writeProblem(w, http.StatusNotFound, code("not_found", "passport"), "passport not found", ppid)
			return nil, false
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return nil, false
	}
	return p, true
}

func (a *API) appendOrFail(w http.ResponseWriter, r *http.Request, ev custody.Event, affected []store.Affected) bool {
	if err := a.st.Append(r.Context(), ev, a.now(), affected); err != nil {
		if errors.Is(err, store.ErrSequenceConflict) {
			writeProblem(w, http.StatusConflict, code("conflict", "sequence"), "concurrent append",
				"re-read the passport head and retry")
			return false
		}
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return false
	}
	a.m.Inc(MetricCommands)
	return true
}

type initReq struct {
	GPID       string `json:"gpid"`
	Holder     string `json:"holder"`
	HolderRole string `json:"holderRole"`
	Quantity   int64  `json:"quantity"`
	Unit       string `json:"unit"`
	ProducedAt int64  `json:"producedAt"`
}

func (a *API) initialize(w http.ResponseWriter, r *http.Request) {
	var req initReq
	if !decode(w, r, &req) {
		return
	}
	// R7 precondition: GPID must be PUBLISHED in Catalog master data
	if a.cat != nil && a.cat.Enabled() {
		ok, err := a.cat.GPIDPublished(r.Context(), req.GPID)
		if err != nil {
			writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "catalog"),
				"catalog unavailable", err.Error())
			return
		}
		if !ok {
			writeProblem(w, http.StatusConflict, code("conflict", "gpid_not_published"),
				"GPID not PUBLISHED", "custody may only be initialized for PUBLISHED catalog products (R7)")
			return
		}
	} else {
		// C3-F9: fail-CLOSED — startup validation requires DKD_CATALOG_URL, so this is unreachable in
		// a valid deployment; if the catalog client is somehow absent, refuse genesis (never bypass R7).
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "catalog"),
			"catalog OHS not configured", "the R7 GPID-PUBLISHED precondition cannot be verified")
		return
	}
	// C3-F5 / FR-PASS: gate genesis on the holder's KYC tier (≥ BASIC). The Identity OHS is the
	// authority (R7); when unconfigured (dev) the gate opens rather than blocking custody.
	if a.identity != nil && a.identity.Enabled() {
		tier, err := a.identity.KycTier(r.Context(), req.Holder)
		if err != nil {
			writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "identity"),
				"identity OHS unavailable", err.Error())
			return
		}
		if tier == "" || tier == "UNVERIFIED" {
			writeProblem(w, http.StatusUnprocessableEntity, code("validation", "holder_kyc_insufficient"),
				"holder KYC tier too low",
				"custody genesis requires the holder KYC-verified to at least BASIC (FR-PASS); tier="+tier)
			return
		}
	}
	p, ev, err := custody.InitializeCustody(custody.InitInput{
		GPID: req.GPID, Holder: req.Holder, HolderRole: custody.Role(req.HolderRole),
		Quantity: req.Quantity, Unit: req.Unit, ProducedAt: req.ProducedAt,
	}, a.now())
	if err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_command"), "invalid command", err.Error())
		return
	}
	if !a.appendOrFail(w, r, ev, []store.Affected{{Head: p, IsNew: true, RowPrevHash: ""}}) {
		return
	}
	writeData(w, http.StatusCreated, p)
}

// transferReq is a dual-signed CUSTODY_TRANSFER command (C3-F2b(ii); BR-005/FR-PASS-010). The
// releasing custodian (fromHolder) and the receiving custodian (toHolder) EACH sign the transfer
// event's eventHash. transferredAt is client-supplied so both parties can precompute the exact
// hash: GET the passport for ppid + HeadHash(=previousHash) + quantity + unit + gpid, build the
// transfer canonical fields, hash them (shared CustodyHash algo), and both sign. quantity/unit/
// gpid/previousHash are SERVER-derived (C2) — the request never carries them.
type transferReq struct {
	FromHolder    string `json:"fromHolder"`
	ToHolder      string `json:"toHolder"`
	ToHolderRole  string `json:"toHolderRole"`
	ReferenceOrd  string `json:"referenceOrd"`
	TransferredAt int64  `json:"transferredAt"`
	FromKeyID     string `json:"fromKeyId"`
	FromSignature string `json:"fromSignature"`
	ToKeyID       string `json:"toKeyId"`
	ToSignature   string `json:"toSignature"`
	// AttestationSignature (C3-F2e), when present, selects the attestation-authority path: a
	// SINGLE base64-std Ed25519 signature by the configured authority over the POD-ATTEST message,
	// authorizing a saga-internal, reference-linked move (POD). Mutually exclusive with the human
	// dual-signature above; only ever accepted when referenceOrd != "".
	AttestationSignature string `json:"attestationSignature"`
}

func (a *API) transfer(w http.ResponseWriter, r *http.Request) {
	var req transferReq
	if !decode(w, r, &req) {
		return
	}
	p, ok := a.loadActive(w, r, r.PathValue("ppid"))
	if !ok {
		return
	}
	// C3-F2e — attestation-authority path (saga-internal, reference-linked move, e.g. a logistics
	// POD: FR-PASS-014 shipment-linked transfer / FR-PASS-070 server-side authorization). Selected
	// ONLY when the request carries an attestationSignature; the human dual-signature gate below is
	// left entirely unchanged for direct callers.
	if req.AttestationSignature != "" {
		a.transferByAttestation(w, r, p, req)
		return
	}
	// BR-005/FR-PASS-010: custody MUST NOT move without a valid dual signature over the transfer's
	// canonical bytes. Resolve BOTH custodians' keys (public keys only; unknown/unbound keys are
	// rejected here), then verify both Ed25519 signatures + key<->party bindings BEFORE sealing.
	fromKey, ok := a.resolveKey(w, r, req.FromKeyID)
	if !ok {
		return
	}
	toKey, ok := a.resolveKey(w, r, req.ToKeyID)
	if !ok {
		return
	}
	// quantity/unit/gpid/previousHash are the loaded passport's SERVER-authoritative values (C2).
	vreq := signing.TransferRequest{
		PPID: p.PPID, GPID: p.GPID, FromHolder: req.FromHolder, ToHolder: req.ToHolder,
		ToHolderRole: req.ToHolderRole, Quantity: p.Quantity, Unit: p.Unit,
		TransferredAt: req.TransferredAt, PreviousHash: p.HeadHash, ReferenceOrd: req.ReferenceOrd,
		FromSignature: req.FromSignature, ToSignature: req.ToSignature,
	}
	if err := signing.VerifyTransfer(vreq, fromKey, toKey); err != nil {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "transfer_signature_invalid"),
			"transfer signature rejected", err.Error())
		return
	}
	prevHead := p.HeadHash
	ev, err := p.Transfer(req.FromHolder, req.ToHolder, custody.Role(req.ToHolderRole), req.ReferenceOrd,
		req.TransferredAt, custody.TransferSig{
			FromKeyID: req.FromKeyID, FromSignature: req.FromSignature,
			ToKeyID: req.ToKeyID, ToSignature: req.ToSignature,
		})
	if err != nil {
		writeProblem(w, http.StatusConflict, code("conflict", "command"), "command rejected", err.Error())
		return
	}
	if !a.appendOrFail(w, r, ev, []store.Affected{{Head: p, IsNew: false, RowPrevHash: prevHead}}) {
		return
	}
	writeData(w, http.StatusOK, p)
}

// transferByAttestation seals a reference-linked custody move authorized by a SINGLE attestation
// authority signature (C3-F2e), distinct from the human dual-signature. It is scoped hard to
// reference-linked moves (referenceOrd MUST be non-empty) so an authority signature can never
// authorize an arbitrary human hand-off, and it FAILS CLOSED when no authority key is configured.
// quantity/unit/gpid/previousHash remain SERVER-derived (C2 — never trusted from the client).
func (a *API) transferByAttestation(w http.ResponseWriter, r *http.Request, p *custody.Passport, req transferReq) {
	// Scope guard: the authority may ONLY authorize reference-linked moves. Without it, a leaked
	// authority key could rubber-stamp any transfer — so an attestation with no referenceOrd is
	// rejected outright (never demoted to the human path).
	if req.ReferenceOrd == "" {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "attestation_reference_required"),
			"attestation transfer rejected", "an attestation-authority transfer must carry a non-empty referenceOrd (C3-F2e)")
		return
	}
	// Fail closed: attestation mode is unavailable unless an authority key is configured.
	if len(a.attestationAuthority) != ed25519.PublicKeySize {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "attestation_unavailable"),
			"attestation transfer rejected", signing.ErrAttestationAuthorityUnset.Error())
		return
	}
	// The authority signs the POD-ATTEST message the logistics client can compute; the server
	// reconstructs it from the path (ppid, C2 server-derived) + body fields, then verifies.
	msg := signing.AttestationMessage(p.PPID, req.FromHolder, req.ToHolder, req.ToHolderRole, req.ReferenceOrd, req.TransferredAt)
	if err := signing.VerifyAttestation(a.attestationAuthority, msg, req.AttestationSignature); err != nil {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "attestation_signature_invalid"),
			"attestation transfer rejected", err.Error())
		return
	}
	prevHead := p.HeadHash
	ev, err := p.Transfer(req.FromHolder, req.ToHolder, custody.Role(req.ToHolderRole), req.ReferenceOrd,
		req.TransferredAt, custody.TransferSig{AttestationSignature: req.AttestationSignature})
	if err != nil {
		writeProblem(w, http.StatusConflict, code("conflict", "command"), "command rejected", err.Error())
		return
	}
	if !a.appendOrFail(w, r, ev, []store.Affected{{Head: p, IsNew: false, RowPrevHash: prevHead}}) {
		return
	}
	writeData(w, http.StatusOK, p)
}

type splitReq struct {
	Allocations []struct {
		Holder     string `json:"holder"`
		HolderRole string `json:"holderRole"`
		Quantity   int64  `json:"quantity"`
	} `json:"allocations"`
}

func (a *API) split(w http.ResponseWriter, r *http.Request) {
	var req splitReq
	if !decode(w, r, &req) {
		return
	}
	p, ok := a.loadActive(w, r, r.PathValue("ppid"))
	if !ok {
		return
	}
	allocs := make([]custody.Alloc, 0, len(req.Allocations))
	for _, al := range req.Allocations {
		allocs = append(allocs, custody.Alloc{Holder: al.Holder, HolderRole: custody.Role(al.HolderRole), Quantity: al.Quantity})
	}
	prevHead := p.HeadHash
	ev, children, err := p.Split(allocs, a.now())
	if err != nil {
		writeProblem(w, http.StatusConflict, code("conflict", "command"), "command rejected", err.Error())
		return
	}
	affected := []store.Affected{{Head: p, IsNew: false, RowPrevHash: prevHead}}
	for _, c := range children {
		affected = append(affected, store.Affected{Head: c, IsNew: true, RowPrevHash: ""})
	}
	if !a.appendOrFail(w, r, ev, affected) {
		return
	}
	writeData(w, http.StatusOK, map[string]any{"parent": p, "children": children})
}

type mergeReq struct {
	SourcePpids  []string `json:"sourcePpids"`
	ToHolder     string   `json:"toHolder"`
	ToHolderRole string   `json:"toHolderRole"`
}

func (a *API) merge(w http.ResponseWriter, r *http.Request) {
	var req mergeReq
	if !decode(w, r, &req) {
		return
	}
	sources := make([]*custody.Passport, 0, len(req.SourcePpids))
	prevHeads := make([]string, 0, len(req.SourcePpids))
	for _, ppid := range req.SourcePpids {
		p, ok := a.loadActive(w, r, ppid)
		if !ok {
			return
		}
		sources = append(sources, p)
		prevHeads = append(prevHeads, p.HeadHash)
	}
	ev, merged, err := custody.Merge(sources, req.ToHolder, custody.Role(req.ToHolderRole), a.now())
	if err != nil {
		writeProblem(w, http.StatusConflict, code("conflict", "command"), "command rejected", err.Error())
		return
	}
	affected := make([]store.Affected, 0, len(sources)+1)
	for i, s := range sources {
		affected = append(affected, store.Affected{Head: s, IsNew: false, RowPrevHash: prevHeads[i]})
	}
	affected = append(affected, store.Affected{Head: merged, IsNew: true, RowPrevHash: ""})
	if !a.appendOrFail(w, r, ev, affected) {
		return
	}
	writeData(w, http.StatusOK, map[string]any{"merged": merged, "sources": sources})
}

type recallReq struct {
	GPID     string `json:"gpid"`
	RecallID string `json:"recallId"`
	Reason   string `json:"reason"`
	IssuedBy string `json:"issuedBy"`
}

func (a *API) recall(w http.ResponseWriter, r *http.Request) {
	var req recallReq
	if !decode(w, r, &req) {
		return
	}
	targets, err := a.st.ActiveByGPID(r.Context(), req.GPID, 0)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	if len(targets) == 0 {
		writeProblem(w, http.StatusNotFound, code("not_found", "active_passports"),
			"no active passports", "no ACTIVE passports for gpid "+req.GPID)
		return
	}
	prevHeads := make([]string, len(targets))
	for i, t := range targets {
		prevHeads[i] = t.HeadHash
	}
	ev, err := custody.RecallProducts(targets, req.RecallID, req.Reason, req.IssuedBy, a.now())
	if err != nil {
		writeProblem(w, http.StatusConflict, code("conflict", "command"), "command rejected", err.Error())
		return
	}
	affected := make([]store.Affected, len(targets))
	for i, t := range targets {
		affected[i] = store.Affected{Head: t, IsNew: false, RowPrevHash: prevHeads[i]}
	}
	if !a.appendOrFail(w, r, ev, affected) {
		return
	}
	writeData(w, http.StatusOK, map[string]any{"recallId": req.RecallID, "recalled": len(targets)})
}

// signReq is the REAL dual Ed25519 co-sign command (C3-F2). Both signatures are base64-std
// Ed25519 over the eventHash hex; signedAt is client-supplied so the client can precompute the
// exact hash (GET the passport for ppid + HeadHash, then hash the semantic fields locally).
type signReq struct {
	AgentDid    string `json:"agentDid"`
	KeyID       string `json:"keyId"`
	Signature   string `json:"signature"`
	CoSignerDid string `json:"coSignerDid"`
	CoKeyID     string `json:"coKeyId"`
	CoSignature string `json:"coSignature"`
	SignedAt    int64  `json:"signedAt"`
}

func (a *API) sign(w http.ResponseWriter, r *http.Request) {
	var req signReq
	if !decode(w, r, &req) {
		return
	}
	p, ok := a.loadActive(w, r, r.PathValue("ppid"))
	if !ok {
		return
	}
	// Resolve BOTH signing keys from the registry (public keys only). Unknown/unbound keys are
	// rejected here; the raw Ed25519 verification + four-eyes happen in signing.Verify.
	agentKey, ok := a.resolveKey(w, r, req.KeyID)
	if !ok {
		return
	}
	coKey, ok := a.resolveKey(w, r, req.CoKeyID)
	if !ok {
		return
	}
	vreq := signing.Request{
		PPID: p.PPID, AgentDid: req.AgentDid, CoSignerDid: req.CoSignerDid,
		SignedAt: req.SignedAt, PreviousHash: p.HeadHash,
		Signature: req.Signature, CoSignature: req.CoSignature,
	}
	if err := signing.Verify(vreq, agentKey, coKey); err != nil {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "cosignature_invalid"),
			"co-signature rejected", err.Error())
		return
	}
	prevHead := p.HeadHash
	ev, err := p.SealCustodialSigned(custody.CustodialSig{
		AgentDid: req.AgentDid, KeyID: req.KeyID, Signature: req.Signature,
		CoSignerDid: req.CoSignerDid, CoKeyID: req.CoKeyID, CoSignature: req.CoSignature,
		SignedAt: req.SignedAt,
	})
	if err != nil {
		writeProblem(w, http.StatusConflict, code("conflict", "command"), "command rejected", err.Error())
		return
	}
	if !a.appendOrFail(w, r, ev, []store.Affected{{Head: p, IsNew: false, RowPrevHash: prevHead}}) {
		return
	}
	writeData(w, http.StatusOK, p)
}

// resolveKey looks a key_id up in the registry and decodes its Ed25519 public key. A missing or
// malformed key is a 422 rejection (the caller stops); ok=false means a problem was written.
func (a *API) resolveKey(w http.ResponseWriter, r *http.Request, keyID string) (signing.ResolvedKey, bool) {
	if keyID == "" {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "key_id_required"),
			"keyId required", "both keyId and coKeyId are required")
		return signing.ResolvedKey{}, false
	}
	pubB64, boundDID, found, err := a.st.GetSignerKey(r.Context(), keyID)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return signing.ResolvedKey{}, false
	}
	if !found {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "unknown_key_id"),
			"unknown keyId", "signing key "+keyID+" is not registered")
		return signing.ResolvedKey{}, false
	}
	pub, err := signing.DecodePublicKey(pubB64)
	if err != nil {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "bad_registered_key"),
			"registered key invalid", err.Error())
		return signing.ResolvedKey{}, false
	}
	return signing.ResolvedKey{PublicKey: pub, BoundDID: boundDID}, true
}

// signerKeyReq registers a signer's PUBLIC key bound to a DID (C3-F2c). The binding is accepted
// ONLY if caSignature is a valid trust-anchor (CA) Ed25519 signature over the canonical binding
// bytes (keyId + "\n" + publicKey + "\n" + did) — see signing.CABindingMessage. An anonymous
// caller, or one binding a key for a DID it does not control, cannot produce that signature and
// is rejected. In production this is the national PKI (FR-PASS-070); here the CA public key is
// configured via DKD_CUSTODY_TRUST_ANCHOR_PUBKEY.
type signerKeyReq struct {
	KeyID       string `json:"keyId"`
	PublicKey   string `json:"publicKey"`   // base64-std 32-byte Ed25519 public key
	DID         string `json:"did"`         //
	CaSignature string `json:"caSignature"` // base64-std Ed25519 CA signature over the binding
}

func (a *API) registerSignerKey(w http.ResponseWriter, r *http.Request) {
	var req signerKeyReq
	if !decode(w, r, &req) {
		return
	}
	if req.KeyID == "" {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_command"), "keyId required", "keyId is required")
		return
	}
	if _, err := dkd.NewDID(req.DID); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_command"), "invalid did", err.Error())
		return
	}
	if _, err := signing.DecodePublicKey(req.PublicKey); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_command"), "invalid public key", err.Error())
		return
	}
	// Root of trust (C3-F2c; FR-PASS-070): reject any binding lacking a valid CA signature. FAIL
	// CLOSED when the trust anchor is unset (ErrTrustAnchorUnset) — never an open fallback.
	if err := signing.VerifyCABinding(a.trustAnchor, req.KeyID, req.PublicKey, req.DID, req.CaSignature); err != nil {
		status, reason := http.StatusUnprocessableEntity, "ca_signature_invalid"
		if errors.Is(err, signing.ErrTrustAnchorUnset) {
			status, reason = http.StatusServiceUnavailable, "trust_anchor_unset"
		}
		writeProblem(w, status, code("validation", reason), "signer-key binding rejected", err.Error())
		return
	}
	if err := a.st.UpsertSignerKey(r.Context(), req.KeyID, req.PublicKey, req.DID, a.now()); err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	writeData(w, http.StatusCreated, map[string]any{"keyId": req.KeyID, "did": req.DID})
}

func (a *API) getPassport(w http.ResponseWriter, r *http.Request) {
	p, ok := a.loadActive(w, r, r.PathValue("ppid"))
	if !ok {
		return
	}
	writeData(w, http.StatusOK, p)
}

func (a *API) listEvents(w http.ResponseWriter, r *http.Request) {
	rows, err := a.st.ListEvents(r.Context(), r.PathValue("ppid"))
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	// C3-F8: cursor pagination over the chain (was: whole chain unbounded). The cursor is the last
	// returned sequence; limit defaults to 200, capped at 500 (SA-CONV-PAGE cursor-only).
	const defaultLimit, maxLimit = 200, 500
	limit := defaultLimit
	if v := r.URL.Query().Get("limit"); v != "" {
		if n, e := strconv.Atoi(v); e == nil && n > 0 {
			limit = n
		}
	}
	if limit > maxLimit {
		limit = maxLimit
	}
	afterSeq := int64(-1)
	if c := r.URL.Query().Get("cursor"); c != "" {
		if n, e := strconv.ParseInt(c, 10, 64); e == nil {
			afterSeq = n
		}
	}
	out := make([]map[string]any, 0, limit)
	var nextCursor string
	var lastSeq int64
	for _, row := range rows {
		if int64(row.Sequence) <= afterSeq {
			continue
		}
		if len(out) >= limit {
			nextCursor = strconv.FormatInt(lastSeq, 10) // more rows remain → next page starts after lastSeq
			break
		}
		var payload map[string]any
		if err := json.Unmarshal(row.Payload, &payload); err != nil {
			a.log.Error("stored payload not decodable — possible corruption",
				"ppid", row.PPID, "sequence", row.Sequence, "err", err)
			writeProblem(w, http.StatusInternalServerError, code("internal", "payload_corrupt"),
				"stored payload not decodable", "chain requires investigation")
			return
		}
		out = append(out, map[string]any{
			"sequence": row.Sequence, "eventType": row.EventType, "eventId": row.EventID,
			"prevHash": row.PrevHash, "eventHash": row.EventHash,
			"occurredAt": row.OccurredAtMs, "payload": payload,
		})
		lastSeq = int64(row.Sequence)
	}
	writeJSON(w, http.StatusOK, "application/json", map[string]any{
		"success": true, "data": out, "error": nil,
		"meta": map[string]any{
			"requestId": obs.CorrelationID(r.Context()), "timestamp": time.Now().UnixMilli(),
			"limit": limit, "nextCursor": nextCursor,
		},
	})
}

func (a *API) verifyChain(w http.ResponseWriter, r *http.Request) {
	ok, detail, err := a.st.VerifyChain(r.Context(), r.PathValue("ppid"))
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, map[string]any{"verified": ok, "detail": detail, "checkedAt": time.Now().UnixMilli()})
}
