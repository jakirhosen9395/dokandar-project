// Hand-authored primitive (PL-04). NOT dkdgen output: this supplies the real
// UUIDv7 generator + strict version/variant validation that the generated
// prefixed-ID constructors (ids.go) delegate their embedded-UUID check to.
// Canon: UUID v7 per RFC 9562 (unix-ms timestamp in the high 48 bits); the
// mandatory ID convention in CLAUDE.md ("IDs: UUID v7").

package dkdplatform

import (
	"crypto/rand"
	"encoding/hex"
	"fmt"
	"time"
)

// NewUUIDv7 returns a fresh RFC-9562 version-7 UUID in canonical 8-4-4-4-12
// lowercase-hex form. Layout: 48-bit big-endian Unix-millisecond timestamp,
// the 4-bit version nibble 0b0111, 74 random bits, and the 2-bit variant
// 0b10. Random bits come from crypto/rand; a read failure panics because an ID
// generator that silently returns a non-random value is a correctness hazard.
func NewUUIDv7() string {
	var b [16]byte
	ms := time.Now().UnixMilli()
	b[0] = byte(ms >> 40)
	b[1] = byte(ms >> 32)
	b[2] = byte(ms >> 24)
	b[3] = byte(ms >> 16)
	b[4] = byte(ms >> 8)
	b[5] = byte(ms)
	if _, err := rand.Read(b[6:]); err != nil {
		panic(fmt.Sprintf("dkdplatform: uuidv7 entropy: %v", err))
	}
	b[6] = (b[6] & 0x0f) | 0x70 // version 7
	b[8] = (b[8] & 0x3f) | 0x80 // variant 10xx (RFC 4122/9562)
	return formatUUID(b)
}

// formatUUID renders 16 bytes as canonical lowercase 8-4-4-4-12 hex.
func formatUUID(b [16]byte) string {
	var buf [36]byte
	hex.Encode(buf[0:8], b[0:4])
	buf[8] = '-'
	hex.Encode(buf[9:13], b[4:6])
	buf[13] = '-'
	hex.Encode(buf[14:18], b[6:8])
	buf[18] = '-'
	hex.Encode(buf[19:23], b[8:10])
	buf[23] = '-'
	hex.Encode(buf[24:36], b[10:16])
	return string(buf[:])
}

// ValidateUUIDv7 rejects anything that is not a canonical version-7 UUID. It
// checks the 36-char shape and hyphen positions, that every non-hyphen char is
// hex, that the version nibble is 7, and that the variant bits are 0b10 — so a
// v4 UUID, an all-zero UUID, or a garbage body is REJECTED (PL-04). Returns nil
// only for a well-formed v7.
func ValidateUUIDv7(s string) error {
	b, err := parseUUID(s)
	if err != nil {
		return err
	}
	if v := b[6] >> 4; v != 7 {
		return fmt.Errorf("uuid %q is version %d, not v7", s, v)
	}
	if b[8]&0xc0 != 0x80 {
		return fmt.Errorf("uuid %q has non-RFC-4122 variant bits", s)
	}
	return nil
}

// parseUUID decodes a canonical 8-4-4-4-12 UUID string into 16 bytes.
func parseUUID(s string) ([16]byte, error) {
	var b [16]byte
	if len(s) != 36 || s[8] != '-' || s[13] != '-' || s[18] != '-' || s[23] != '-' {
		return b, fmt.Errorf("uuid %q is not canonical 8-4-4-4-12 form", s)
	}
	groups := [5][2]int{{0, 8}, {9, 13}, {14, 18}, {19, 23}, {24, 36}}
	dst := 0
	for _, g := range groups {
		n, err := hex.Decode(b[dst:dst+(g[1]-g[0])/2], []byte(s[g[0]:g[1]]))
		if err != nil {
			return b, fmt.Errorf("uuid %q has non-hex characters: %w", s, err)
		}
		dst += n
	}
	return b, nil
}

// validateEmbeddedV7 checks that the trailing 36 characters of a prefixed-ID
// body are a valid UUIDv7. The trailing-segment rule tolerates an optional
// category segment (e.g. a "GP-<cat>-<uuid7>" catalog id) while still pinning
// the canonical UUID to v7. Used by the generated constructors in ids.go.
func validateEmbeddedV7(body string) error {
	if len(body) < 36 {
		return fmt.Errorf("id body %q is too short to embed a UUIDv7", body)
	}
	return ValidateUUIDv7(body[len(body)-36:])
}
