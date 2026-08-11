// Package logistics — Shipment aggregate (DM Context #9; DM vocabulary wins per ADR-016;
// IN_TRANSIT removed per M-SELF-1). POD is a CUSTODY fact: logistics attests delivery to
// custody-ledger-svc (R1 sole writer) and its own DeliveryRecorded.v1 is advisory only.
package logistics

import (
	"crypto/rand"
	"fmt"
	"time"
)

type Status string

const (
	StatusPending       Status = "PENDING"
	StatusRiderAssigned Status = "RIDER_ASSIGNED"
	StatusPickedUp      Status = "PICKED_UP"
	StatusDelivered     Status = "DELIVERED"
	StatusCancelled     Status = "CANCELLED"
	StatusFailed        Status = "FAILED"
)

var legal = map[Status][]Status{
	StatusPending:       {StatusRiderAssigned, StatusCancelled},
	StatusRiderAssigned: {StatusPickedUp, StatusCancelled},
	StatusPickedUp:      {StatusDelivered, StatusFailed, StatusCancelled},
	StatusDelivered:     {},
	StatusCancelled:     {},
	StatusFailed:        {},
}

func CanTransition(from, to Status) bool {
	for _, s := range legal[from] {
		if s == to {
			return true
		}
	}
	return false
}

func IsTerminal(s Status) bool { return len(legal[s]) == 0 }

func ValidStatus(s Status) bool { _, ok := legal[s]; return ok }

func ValidReferenceType(t string) bool { return t == "ORDER" || t == "TRADE" }

// NewSHP mints SHP-{uuid7} (DM ID conventions).
func NewSHP() string { return "SHP-" + UUID7() }

func UUID7() string {
	var b [16]byte
	if _, err := rand.Read(b[:]); err != nil {
		panic("uuid7: entropy source failed: " + err.Error()) // never mint a degraded ID
	}
	ms := uint64(time.Now().UnixMilli())
	b[0], b[1], b[2] = byte(ms>>40), byte(ms>>32), byte(ms>>24)
	b[3], b[4], b[5] = byte(ms>>16), byte(ms>>8), byte(ms)
	b[6] = (b[6] & 0x0f) | 0x70
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}
