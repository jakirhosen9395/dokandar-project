package api

import (
	"context"
	"encoding/json"
	"io"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"log/slog"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/clients"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/events"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/logistics"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/obs"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/store"
)

// fakeStore implements shipmentStore in-memory so the POD fail-closed rule can be
// asserted without a live Postgres. It records whether a Transition (the DELIVERED
// write) happened and which outbox event it carried.
type fakeStore struct {
	ship         store.Shipment
	getErr       error
	transitioned bool
	lastEvent    store.OutboxRow
}

func (f *fakeStore) Get(_ context.Context, _ string) (store.Shipment, error) {
	return f.ship, f.getErr
}

func (f *fakeStore) Transition(_ context.Context, _ string, _ []logistics.Status, to logistics.Status,
	_ map[string]any, ev store.OutboxRow, _ int64) (store.Shipment, error) {
	f.transitioned = true
	f.lastEvent = ev
	updated := f.ship
	updated.Status = to
	return updated, nil
}

func (f *fakeStore) CreateShipment(_ context.Context, _, _, _ string,
	_, _ json.RawMessage, _ func(shp string) store.OutboxRow, _ int64) (store.Shipment, bool, error) {
	return store.Shipment{}, false, nil
}

// fakeClient implements custodyClient; records whether the custody attestation was invoked.
type fakeClient struct {
	attestCalled  bool
	gotTransferAt int64
	status        int
	err           error
}

func (c *fakeClient) Enabled() bool { return false }
func (c *fakeClient) InternalOrder(_ context.Context, _ string) (clients.InternalOrder, error) {
	return clients.InternalOrder{}, nil
}
func (c *fakeClient) AttestDelivery(_ context.Context, _, _ string, transferredAt int64, _ clients.Attestation) (int, error) {
	c.attestCalled = true
	c.gotTransferAt = transferredAt
	return c.status, c.err
}

func newTestAPI(st shipmentStore, cl custodyClient) *API {
	return &API{
		st:  st,
		cl:  cl,
		m:   obs.NewMetrics(),
		log: slog.New(slog.NewTextHandler(io.Discard, nil)),
		now: func() int64 { return 1 },
	}
}

func pickedUpShipment() store.Shipment {
	return store.Shipment{
		SHP:           "SHP-00000000-0000-7000-8000-000000000001",
		ReferenceID:   "ORD-00000000-0000-7000-8000-000000000001",
		ReferenceType: "ORDER",
		Status:        logistics.StatusPickedUp,
		CreatedAt:     1750000000000,
	}
}

func doPOD(t *testing.T, a *API, body string) *httptest.ResponseRecorder {
	t.Helper()
	mux := http.NewServeMux()
	a.Register(mux)
	req := httptest.NewRequest(http.MethodPost,
		"/v1/logistics/shipments/SHP-00000000-0000-7000-8000-000000000001/pod",
		strings.NewReader(body))
	req.Header.Set("Idempotency-Key", "pod-test-key")
	req.Header.Set("Content-Type", "application/json")
	rec := httptest.NewRecorder()
	mux.ServeHTTP(rec, req)
	return rec
}

// TestPODRejectsMissingAttestation is the LOG-01 / Saga-3 regression guard: a POD with NO
// custody attestation must be REJECTED (422) and must NOT transition to DELIVERED nor emit
// DeliveryRecorded (which finance consumes to release escrow). Fail closed.
func TestPODRejectsMissingAttestation(t *testing.T) {
	st := &fakeStore{ship: pickedUpShipment()}
	cl := &fakeClient{status: 200}
	a := newTestAPI(st, cl)

	rec := doPOD(t, a, `{"podPhotoUrl":"https://sink.local/x.jpg"}`) // no "attestation"

	if rec.Code != http.StatusUnprocessableEntity {
		t.Fatalf("nil-attestation POD: got HTTP %d, want 422; body=%s", rec.Code, rec.Body.String())
	}
	if st.transitioned {
		t.Fatalf("nil-attestation POD must NOT transition to DELIVERED")
	}
	if st.lastEvent.Topic != "" {
		t.Fatalf("nil-attestation POD must NOT emit an event; got topic=%q", st.lastEvent.Topic)
	}
	if cl.attestCalled {
		t.Fatalf("nil-attestation POD must not call custody (nothing to attest)")
	}
	// The rejection must carry the taxonomy-valid business code, never bad_code.
	var prob struct {
		Status int    `json:"status"`
		Code   string `json:"code"`
	}
	_ = json.Unmarshal(rec.Body.Bytes(), &prob)
	if prob.Code != "dokandar.logistics.validation.attestation_required" {
		t.Fatalf("unexpected problem code %q", prob.Code)
	}
}

// TestPODAcceptsValidAttestation proves the positive path is unaffected: a POD WITH a valid
// attestation that custody accepts (2xx) transitions to DELIVERED and emits DeliveryRecorded.
func TestPODAcceptsValidAttestation(t *testing.T) {
	st := &fakeStore{ship: pickedUpShipment()}
	cl := &fakeClient{status: 200}
	a := newTestAPI(st, cl)

	body := `{"podPhotoUrl":"https://sink.local/x.jpg","attestation":` +
		`{"ppid":"PPID-00000000-0000-7000-8000-000000000001","fromHolder":"did:dokandar:00000000-0000-7000-8000-0000000000a1",` +
		`"toHolder":"did:dokandar:00000000-0000-7000-8000-0000000000b2","toHolderRole":"CONSUMER"}}`
	rec := doPOD(t, a, body)

	if rec.Code != http.StatusOK {
		t.Fatalf("valid-attestation POD: got HTTP %d, want 200; body=%s", rec.Code, rec.Body.String())
	}
	if !cl.attestCalled {
		t.Fatalf("valid-attestation POD must call custody attestation")
	}
	// C3-F2e: the attestation transferredAt must be the shipment's immutable createdAt (stable
	// across retries so custody's "pod:<shp>" idempotency key replays cleanly).
	if cl.gotTransferAt != 1750000000000 {
		t.Fatalf("attestation transferredAt must equal shipment.CreatedAt; got %d", cl.gotTransferAt)
	}
	if !st.transitioned {
		t.Fatalf("valid-attestation POD must transition to DELIVERED")
	}
	wantTopic := events.DeliveryRecorded("x", "ORD-x", "ORDER", 1, 1).Topic
	if st.lastEvent.Topic != wantTopic {
		t.Fatalf("valid-attestation POD must emit DeliveryRecorded (%s); got %q", wantTopic, st.lastEvent.Topic)
	}
}

// TestPODCustodyOutageStaysRetryable proves the forward guard: an attested POD hitting a
// custody OUTAGE (5xx) is 503 retryable, NOT a permanent drop, and does not mark DELIVERED.
func TestPODCustodyOutageStaysRetryable(t *testing.T) {
	st := &fakeStore{ship: pickedUpShipment()}
	cl := &fakeClient{status: 503}
	a := newTestAPI(st, cl)

	body := `{"attestation":{"ppid":"PPID-00000000-0000-7000-8000-000000000001",` +
		`"fromHolder":"did:dokandar:00000000-0000-7000-8000-0000000000a1",` +
		`"toHolder":"did:dokandar:00000000-0000-7000-8000-0000000000b2","toHolderRole":"CONSUMER"}}`
	rec := doPOD(t, a, body)

	if rec.Code != http.StatusServiceUnavailable {
		t.Fatalf("custody-outage POD: got HTTP %d, want 503; body=%s", rec.Code, rec.Body.String())
	}
	if st.transitioned {
		t.Fatalf("custody-outage POD must NOT transition to DELIVERED")
	}
}
