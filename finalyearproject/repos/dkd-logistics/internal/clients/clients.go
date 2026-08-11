// Package clients — logistics' outbound seams. B2C internal REST supplies the delivery
// address (the ONLY reader, FR-MKT-004). Custody attestation realizes "POD is a custody
// event, never a stock write" (R1): logistics only ATTESTS via custody's own command
// (REST substitution for the DeliveryAttestation gRPC OHS — fleet decision D9-class);
// custody remains the sole writer and validator.
package clients

import (
	"bytes"
	"context"
	"crypto/ed25519"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"strconv"
	"time"
)

type HTTP struct {
	B2CBaseURL     string
	CustodyBaseURL string
	client         *http.Client
	// attestKey signs the POD-ATTEST message so custody can authorize the reference-linked move via
	// the single attestation-authority signature (C3-F2e). nil => no attestationSignature is sent.
	// The raw key bytes are NEVER logged or printed.
	attestKey ed25519.PrivateKey
	log       *slog.Logger
}

// New builds the logistics outbound-seam client. attestPrivKeyB64 is the base64-std Ed25519 private
// key (32-byte seed OR 64-byte full key) used to sign POD attestations (C3-F2e); empty/invalid =>
// attestation signing is disabled (logged, never fatal) so non-POD environments still start. The
// private key is parsed once and never printed.
func New(b2cURL, custodyURL, attestPrivKeyB64 string, log *slog.Logger) *HTTP {
	h := &HTTP{B2CBaseURL: b2cURL, CustodyBaseURL: custodyURL,
		client: &http.Client{Timeout: 8 * time.Second}, log: log}
	if attestPrivKeyB64 != "" {
		if k, err := decodeEd25519Priv(attestPrivKeyB64); err != nil {
			if log != nil {
				log.Warn("DKD_LOGISTICS_ATTESTATION_PRIVKEY is set but could not be parsed — POD attestation signing DISABLED", "err", err.Error())
			}
		} else {
			h.attestKey = k
			if log != nil {
				log.Info("POD attestation signing ENABLED (C3-F2e)")
			}
		}
	} else if log != nil {
		log.Warn("DKD_LOGISTICS_ATTESTATION_PRIVKEY unset — POD posts no attestationSignature (C3-F2e attestation path disabled)")
	}
	return h
}

// decodeEd25519Priv accepts a base64-std Ed25519 32-byte seed or 64-byte full private key. It never
// echoes the key material in its errors.
func decodeEd25519Priv(b64 string) (ed25519.PrivateKey, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("clients: attestation private key is not valid base64-std")
	}
	switch len(raw) {
	case ed25519.SeedSize:
		return ed25519.NewKeyFromSeed(raw), nil
	case ed25519.PrivateKeySize:
		return ed25519.PrivateKey(raw), nil
	default:
		return nil, fmt.Errorf("clients: attestation private key must be a 32-byte seed or 64-byte key, got %d bytes", len(raw))
	}
}

func (h *HTTP) Enabled() bool { return h.B2CBaseURL != "" }

type InternalOrder struct {
	Ord             string          `json:"ord"`
	SellerDid       string          `json:"sellerDid"`
	BuyerDid        string          `json:"buyerDid"`
	Status          string          `json:"status"`
	DeliveryAddress json.RawMessage `json:"deliveryAddress"`
}

// InternalOrder fetches {ord, sellerDid, deliveryAddress} from B2C (DM R7 checklist seam).
func (h *HTTP) InternalOrder(ctx context.Context, ord string) (InternalOrder, error) {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet,
		h.B2CBaseURL+"/internal/orders/"+ord, nil)
	if err != nil {
		return InternalOrder{}, err
	}
	res, err := h.client.Do(req)
	if err != nil {
		return InternalOrder{}, fmt.Errorf("clients: b2c internal order: %w", err)
	}
	defer func() { _ = res.Body.Close() }()
	body, rErr := io.ReadAll(io.LimitReader(res.Body, 1<<20))
	if rErr != nil {
		return InternalOrder{}, fmt.Errorf("clients: read b2c body: %w", rErr)
	}
	if res.StatusCode != http.StatusOK {
		return InternalOrder{}, fmt.Errorf("clients: b2c internal order %s: status %d", ord, res.StatusCode)
	}
	var env struct {
		Data InternalOrder `json:"data"`
	}
	if err := json.Unmarshal(body, &env); err != nil {
		return InternalOrder{}, fmt.Errorf("clients: b2c envelope: %w", err)
	}
	return env.Data, nil
}

type Attestation struct {
	PPID         string `json:"ppid"`
	FromHolder   string `json:"fromHolder"`
	ToHolder     string `json:"toHolder"`
	ToHolderRole string `json:"toHolderRole"`
}

// attestationMessage is the EXACT byte string custody's internal/signing.AttestationMessage
// reconstructs and verifies (C3-F2e). It MUST match custody byte-for-byte, so any change here or in
// custody must move in lockstep. transferredAt is base-10, no padding (matches Go strconv on both).
func attestationMessage(ppid, fromHolder, toHolder, toHolderRole, referenceOrd string, transferredAt int64) []byte {
	return []byte("POD-ATTEST\n" + ppid + "\n" + fromHolder + "\n" + toHolder + "\n" +
		toHolderRole + "\n" + referenceOrd + "\n" + strconv.FormatInt(transferredAt, 10))
}

// AttestDelivery invokes custody's TransferCustody with an idempotency key derived from
// the shipment ("pod:<shp>"). 2xx = appended; 4xx = custody REJECTED the attestation
// (invalid POD — surfaced to the caller, never papered over); 5xx = retryable.
//
// C3-F2e: a POD is a saga-internal, reference-linked custody move, NOT a human hand-off — so when an
// attestation key is configured logistics signs the POD-ATTEST message and posts a single
// attestationSignature (custody authorizes it via the trusted authority key). transferredAt is
// caller-supplied and MUST be STABLE for a given shipment so retries reproduce the identical request
// body and custody's "pod:<shp>" idempotency key replays cleanly (the caller passes the shipment's
// immutable createdAt). If no key is configured the payload is unsigned (unchanged pre-C3-F2e shape),
// so non-POD environments do not break. The private key is NEVER logged.
func (h *HTTP) AttestDelivery(ctx context.Context, shp, referenceOrd string, transferredAt int64, a Attestation) (int, error) {
	if h.CustodyBaseURL == "" {
		return 0, fmt.Errorf("clients: custody URL not configured")
	}
	body := map[string]any{
		"fromHolder": a.FromHolder, "toHolder": a.ToHolder, "toHolderRole": a.ToHolderRole,
		"referenceOrd": referenceOrd, "transferredAt": transferredAt,
	}
	if h.attestKey != nil {
		msg := attestationMessage(a.PPID, a.FromHolder, a.ToHolder, a.ToHolderRole, referenceOrd, transferredAt)
		body["attestationSignature"] = base64.StdEncoding.EncodeToString(ed25519.Sign(h.attestKey, msg))
	}
	payload, err := json.Marshal(body)
	if err != nil {
		return 0, err
	}
	req, err := http.NewRequestWithContext(ctx, http.MethodPost,
		h.CustodyBaseURL+"/v1/custody/passports/"+a.PPID+"/transfer", bytes.NewReader(payload))
	if err != nil {
		return 0, err
	}
	req.Header.Set("Content-Type", "application/json")
	req.Header.Set("Idempotency-Key", "pod:"+shp)
	res, err := h.client.Do(req)
	if err != nil {
		return 0, fmt.Errorf("clients: custody attest: %w", err)
	}
	defer func() { _ = res.Body.Close() }()
	_, _ = io.Copy(io.Discard, io.LimitReader(res.Body, 1<<16))
	return res.StatusCode, nil
}
