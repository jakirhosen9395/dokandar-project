// Package api — /v1/logistics REST seam (SA §12.5; Idempotency-Key on unsafe writes).
// POD: a custody attestation is MANDATORY and happens BEFORE the local DELIVERED transition —
// custody (R1) is the authority. No attestation → 422 (no DELIVERED, no DeliveryRecorded);
// a custody rejection fails the POD (409); a custody outage is retryable (503).
package api

import (
	"context"
	"encoding/json"
	"errors"
	"net/http"

	"log/slog"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"

	"gitlab.com/final-year-project3354127/logistics-svc/internal/clients"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/events"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/logistics"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/obs"
	"gitlab.com/final-year-project3354127/logistics-svc/internal/store"
)

const (
	MetricShipments = "logistics_shipments_total"
	MetricPods      = "logistics_pods_total"
)

// shipmentStore is the narrow persistence port the REST seam depends on (interface at the
// point of use; *store.Store satisfies it). Keeping it small lets the POD fail-closed rule
// be unit-tested with a fake, without a live Postgres.
type shipmentStore interface {
	Get(ctx context.Context, shp string) (store.Shipment, error)
	Transition(ctx context.Context, shp string, from []logistics.Status, to logistics.Status,
		set map[string]any, outboxEvent store.OutboxRow, now int64) (store.Shipment, error)
	RecordLocation(ctx context.Context, shp string, lat, lng float64, at int64) error
	Track(ctx context.Context, shp string, limit int) ([]store.LocationPoint, error)
	CreateShipment(ctx context.Context, idemKey, refID, refType string,
		pickup, delivery json.RawMessage, mkEvent func(shp string) store.OutboxRow, now int64) (store.Shipment, bool, error)
}

// custodyClient is the narrow outbound port for the custody attestation (R1) + B2C address
// seam. *clients.HTTP satisfies it.
type custodyClient interface {
	Enabled() bool
	InternalOrder(ctx context.Context, ord string) (clients.InternalOrder, error)
	AttestDelivery(ctx context.Context, shp, referenceOrd string, transferredAt int64, a clients.Attestation) (int, error)
}

// queuePublisher is the narrow outbound port for LOG-10 intra-context RabbitMQ notifications.
type queuePublisher interface {
	Publish(queue string, body []byte) error
}

type API struct {
	st  shipmentStore
	cl  custodyClient
	m   *obs.Metrics
	log *slog.Logger
	now func() int64
	pub queuePublisher
}

func New(st *store.Store, cl *clients.HTTP, m *obs.Metrics, log *slog.Logger, now func() int64, pub queuePublisher) *API {
	return &API{st: st, cl: cl, m: m, log: log, now: now, pub: pub}
}

func (a *API) Register(mux *http.ServeMux) {
	mux.HandleFunc("POST /v1/logistics/shipments", a.create)
	mux.HandleFunc("GET /v1/logistics/shipments/{shp}", a.get)
	mux.HandleFunc("POST /v1/logistics/shipments/{shp}/assign-rider", a.assignRider)
	mux.HandleFunc("POST /v1/logistics/shipments/{shp}/pickup", a.pickup)
	mux.HandleFunc("POST /v1/logistics/shipments/{shp}/pod", a.pod)
	mux.HandleFunc("POST /v1/logistics/shipments/{shp}/fail", a.fail)
	mux.HandleFunc("POST /v1/logistics/shipments/{shp}/cancel", a.cancel)
	mux.HandleFunc("POST /v1/logistics/shipments/{shp}/location", a.recordLocation) // LOG-04 GPS ingest
	mux.HandleFunc("GET /v1/logistics/shipments/{shp}/track", a.track)              // LOG-04 live track
}

func code(category, reason string) string {
	c, err := dkd.ErrorCode("logistics", category, reason)
	if err != nil {
		return "dokandar.logistics.internal.bad_code"
	}
	return c
}

func writeJSON(w http.ResponseWriter, status int, ct string, body any) {
	w.Header().Set("Content-Type", ct)
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(body)
}

func writeData(w http.ResponseWriter, status int, data any) {
	writeJSON(w, status, "application/json",
		map[string]any{"success": true, "data": data, "error": nil})
}

func writeProblem(w http.ResponseWriter, status int, codeStr, title, detail string) {
	writeJSON(w, status, "application/problem+json", map[string]any{
		"type": "about:blank", "title": title, "status": status, "code": codeStr, "detail": detail,
	})
}

func requireIdem(w http.ResponseWriter, r *http.Request) (string, bool) {
	k := r.Header.Get("Idempotency-Key")
	if k == "" {
		writeProblem(w, http.StatusBadRequest, code("validation", "idempotency_key_required"),
			"Idempotency-Key required", "unsafe logistics writes are idempotent commands")
		return "", false
	}
	return k, true
}

func decode(w http.ResponseWriter, r *http.Request, into any) bool {
	if err := json.NewDecoder(r.Body).Decode(into); err != nil {
		writeProblem(w, http.StatusBadRequest, code("validation", "invalid_json"), "invalid JSON", err.Error())
		return false
	}
	return true
}

type createReq struct {
	ReferenceID   string          `json:"referenceId"`
	ReferenceType string          `json:"referenceType"`
	PickupAddress json.RawMessage `json:"pickupAddress"`
}

func (a *API) create(w http.ResponseWriter, r *http.Request) {
	idemKey, ok := requireIdem(w, r)
	if !ok {
		return
	}
	var req createReq
	if !decode(w, r, &req) {
		return
	}
	if req.ReferenceID == "" || !logistics.ValidReferenceType(req.ReferenceType) {
		// LOG-08 / EF-API-3: well-formed request, invalid VALUE → 422 (malformed JSON stays 400).
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "reference"),
			"invalid reference", "referenceId and referenceType ORDER|TRADE are required")
		return
	}
	var delivery json.RawMessage
	if req.ReferenceType == "ORDER" && a.cl.Enabled() {
		io, err := a.cl.InternalOrder(r.Context(), req.ReferenceID)
		if err != nil {
			writeProblem(w, http.StatusConflict, code("conflict", "order_unknown"),
				"order lookup failed", "B2C did not resolve the order for this shipment")
			return
		}
		delivery = io.DeliveryAddress
	}
	now := a.now()
	sh, created, err := a.st.CreateShipment(r.Context(), idemKey, req.ReferenceID, req.ReferenceType,
		req.PickupAddress, delivery,
		func(shp string) store.OutboxRow {
			return events.ShipmentCreated(shp, req.ReferenceID, req.ReferenceType, now)
		}, now)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	if created {
		a.m.Inc(MetricShipments)
	}
	writeData(w, http.StatusCreated, sh)
}

func (a *API) get(w http.ResponseWriter, r *http.Request) {
	sh, err := a.st.Get(r.Context(), r.PathValue("shp"))
	if errors.Is(err, store.ErrNotFound) {
		writeProblem(w, http.StatusNotFound, code("not_found", "shipment"), "shipment not found", r.PathValue("shp"))
		return
	}
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, sh)
}

// LOG-04: ingest a GPS telemetry point for a shipment (live tracking).
func (a *API) recordLocation(w http.ResponseWriter, r *http.Request) {
	shp := r.PathValue("shp")
	var req struct {
		Lat *float64 `json:"lat"`
		Lng *float64 `json:"lng"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Lat == nil || req.Lng == nil || *req.Lat < -90 || *req.Lat > 90 || *req.Lng < -180 || *req.Lng > 180 {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "coordinates"),
			"lat/lng required and in range", "lat[-90,90], lng[-180,180]")
		return
	}
	if _, err := a.st.Get(r.Context(), shp); errors.Is(err, store.ErrNotFound) {
		writeProblem(w, http.StatusNotFound, code("not_found", "shipment"), "shipment not found", shp)
		return
	}
	if err := a.st.RecordLocation(r.Context(), shp, *req.Lat, *req.Lng, a.now()); err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, map[string]any{"shipmentId": shp, "recorded": true})
}

// LOG-04: return a shipment's recent GPS track (newest first).
func (a *API) track(w http.ResponseWriter, r *http.Request) {
	shp := r.PathValue("shp")
	pts, err := a.st.Track(r.Context(), shp, 100)
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	writeData(w, http.StatusOK, map[string]any{"shipmentId": shp, "points": pts})
}

func (a *API) assignRider(w http.ResponseWriter, r *http.Request) {
	var req struct {
		RiderDid string `json:"riderDid"`
	}
	if _, ok := requireIdem(w, r); !ok {
		return
	}
	if !decode(w, r, &req) {
		return
	}
	if _, err := dkd.NewDID(req.RiderDid); err != nil {
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "rider_did"), "invalid riderDid", err.Error())
		return
	}
	now := a.now()
	shp := r.PathValue("shp")
	a.transition(w, r, shp, []logistics.Status{logistics.StatusPending}, logistics.StatusRiderAssigned,
		map[string]any{"assigned_rider_did": req.RiderDid}, events.RiderAssigned(shp, req.RiderDid, now), now)
}

func (a *API) pickup(w http.ResponseWriter, r *http.Request) {
	if _, ok := requireIdem(w, r); !ok {
		return
	}
	now := a.now()
	shp := r.PathValue("shp")
	a.transition(w, r, shp, []logistics.Status{logistics.StatusRiderAssigned}, logistics.StatusPickedUp,
		map[string]any{}, events.PickupRecorded(shp, now), now)
}

type podReq struct {
	PodPhotoURL string               `json:"podPhotoUrl"`
	DeliveredAt int64                `json:"deliveredAt"`
	Attestation *clients.Attestation `json:"attestation"`
}

func (a *API) pod(w http.ResponseWriter, r *http.Request) {
	if _, ok := requireIdem(w, r); !ok {
		return
	}
	var req podReq
	if !decode(w, r, &req) {
		return
	}
	now := a.now()
	shp := r.PathValue("shp")
	sh, err := a.st.Get(r.Context(), shp)
	if errors.Is(err, store.ErrNotFound) {
		writeProblem(w, http.StatusNotFound, code("not_found", "shipment"), "shipment not found", shp)
		return
	}
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	// POD is a custody event, never a stock write (R1): the custody attestation is MANDATORY.
	// A POD that writes no provenance fact must NOT mark the shipment DELIVERED nor emit
	// DeliveryRecorded.v1 (finance consumes that to RELEASE escrow — money would move against a
	// delivery with no custody fact; R1/BR-031). Fail CLOSED. This is NOT a silent drop: the
	// rider gets a clear 422 and resubmits WITH an attestation, and a custody OUTAGE stays
	// retryable via the 503 branch below — so the delivery is held, never lost (F-2 forward guard).
	if req.Attestation == nil {
		a.log.Warn("POD rejected — custody attestation required (R1/BR-031)", "shp", shp)
		writeProblem(w, http.StatusUnprocessableEntity, code("validation", "attestation_required"),
			"custody attestation required for POD",
			"delivery cannot be recorded without a custody attestation (R1/BR-031)")
		return
	}
	// transferredAt = the shipment's immutable createdAt: STABLE across POD retries so the request
	// body (and its POD-ATTEST signature) is reproducible and custody's "pod:<shp>" idempotency
	// key replays cleanly instead of tripping the reused-key-different-body guard (C3-F2e).
	status, aErr := a.cl.AttestDelivery(r.Context(), shp, sh.ReferenceID, sh.CreatedAt, *req.Attestation)
	if aErr != nil || status >= 500 {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "custody"),
			"custody attestation unavailable", "retry the POD — attestation is never dropped")
		return
	}
	if status >= 400 {
		writeProblem(w, http.StatusConflict, code("conflict", "attestation_rejected"),
			"custody rejected the POD attestation", "custody is the provenance authority (R1)")
		return
	}
	deliveredAt := req.DeliveredAt
	if deliveredAt == 0 {
		deliveredAt = now
	}
	set := map[string]any{"delivered_at": deliveredAt}
	if req.PodPhotoURL != "" {
		set["pod_photo_url"] = req.PodPhotoURL
	}
	if a.transition(w, r, shp, []logistics.Status{logistics.StatusPickedUp}, logistics.StatusDelivered,
		set, events.DeliveryRecorded(shp, sh.ReferenceID, sh.ReferenceType, deliveredAt, now), now) {
		a.m.Inc(MetricPods) // only committed deliveries count (reviewer M-3)
	}
}

func (a *API) fail(w http.ResponseWriter, r *http.Request) {
	if _, ok := requireIdem(w, r); !ok {
		return
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Reason == "" {
		req.Reason = "EXC_UNSPECIFIED"
	}
	now := a.now()
	shp := r.PathValue("shp")
	sh, err := a.st.Get(r.Context(), shp)
	if errors.Is(err, store.ErrNotFound) {
		writeProblem(w, http.StatusNotFound, code("not_found", "shipment"), "shipment not found", shp)
		return
	}
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	a.transition(w, r, shp, []logistics.Status{logistics.StatusPickedUp}, logistics.StatusFailed,
		map[string]any{"reason": req.Reason},
		events.DeliveryFailed(shp, sh.ReferenceID, sh.ReferenceType, req.Reason, now), now)
}

func (a *API) cancel(w http.ResponseWriter, r *http.Request) {
	if _, ok := requireIdem(w, r); !ok {
		return
	}
	var req struct {
		Reason string `json:"reason"`
	}
	if !decode(w, r, &req) {
		return
	}
	if req.Reason == "" {
		req.Reason = "CANCELLED"
	}
	now := a.now()
	shp := r.PathValue("shp")
	sh, err := a.st.Get(r.Context(), shp)
	if errors.Is(err, store.ErrNotFound) {
		writeProblem(w, http.StatusNotFound, code("not_found", "shipment"), "shipment not found", shp)
		return
	}
	if err != nil {
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
		return
	}
	a.transition(w, r, shp,
		[]logistics.Status{logistics.StatusPending, logistics.StatusRiderAssigned, logistics.StatusPickedUp},
		logistics.StatusCancelled, map[string]any{"reason": req.Reason},
		events.ShipmentCancelled(shp, sh.ReferenceID, sh.ReferenceType, req.Reason, now), now)
}

func (a *API) transition(w http.ResponseWriter, r *http.Request, shp string,
	from []logistics.Status, to logistics.Status, set map[string]any, ev store.OutboxRow, now int64) bool {
	sh, err := a.st.Transition(r.Context(), shp, from, to, set, ev, now)
	switch {
	case errors.Is(err, store.ErrNotFound):
		writeProblem(w, http.StatusNotFound, code("not_found", "shipment"), "shipment not found", shp)
	case errors.Is(err, store.ErrConflict):
		writeProblem(w, http.StatusConflict, code("conflict", "bad_transition"),
			"ERR_BAD_TRANSITION", err.Error())
	case err != nil:
		writeProblem(w, http.StatusServiceUnavailable, code("infrastructure", "store"), "store failure", err.Error())
	default:
		// LOG-10: fan out an intra-context RabbitMQ notification on the two lifecycle milestones.
		a.notifyIntraContext(to, shp)
		writeData(w, http.StatusOK, sh)
		return true
	}
	return false
}

// notifyIntraContext publishes the R6-exempt intra-context queue messages (best-effort — a broker
// hiccup must never fail the already-committed transition).
func (a *API) notifyIntraContext(to logistics.Status, shp string) {
	if a.pub == nil {
		return
	}
	var queue string
	switch to {
	case logistics.StatusRiderAssigned:
		queue = "logistics.rider-assignment"
	case logistics.StatusDelivered:
		queue = "logistics.delivery-notification"
	default:
		return
	}
	body := []byte(`{"shipmentId":"` + shp + `","status":"` + string(to) + `"}`)
	if err := a.pub.Publish(queue, body); err != nil {
		a.log.Warn("intra-context notify failed (non-fatal)", "queue", queue, "shp", shp, "err", err.Error())
	}
}
