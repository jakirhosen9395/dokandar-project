package scheduler

import (
	"crypto/rand"
	"fmt"
	"time"
)

// NewUUID7 mints a UUID v7 event id (DM ID conventions; fleet pattern).
func NewUUID7() string {
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
