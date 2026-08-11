package catalog

import (
	"crypto/rand"
	"fmt"
	"regexp"
	"time"

	dkd "gitlab.com/final-year-project3354127/dkd-platform-libs/sdk/go"
)

// GPID format is frozen in ids.yaml: GP-{categoryCode}-{uuid7}. catalog-svc is the SOLE issuer (R7).
// The categoryCode coding scheme is NEEDS-INFO in canon: we accept a caller-supplied lowercase
// alphanumeric token (2-12 chars) and do NOT invent a category registry.
var (
	categoryCodeRe = regexp.MustCompile(`^[a-z0-9]{2,12}$`)
	uuid7Re        = regexp.MustCompile(`^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$`)
)

// uuidv7New returns an RFC 9562 UUIDv7 (time-ordered) in canonical lowercase form.
func uuidv7New() string {
	var b [16]byte
	ms := uint64(time.Now().UnixMilli())
	b[0] = byte(ms >> 40)
	b[1] = byte(ms >> 32)
	b[2] = byte(ms >> 24)
	b[3] = byte(ms >> 16)
	b[4] = byte(ms >> 8)
	b[5] = byte(ms)
	if _, err := rand.Read(b[6:]); err != nil {
		panic(fmt.Sprintf("uuidv7: entropy unavailable: %v", err))
	}
	b[6] = 0x70 | (b[6] & 0x0f) // version 7
	b[8] = 0x80 | (b[8] & 0x3f) // RFC 4122 variant
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// NewGPID7 mints a new GPID for the given category code.
func NewGPID7(categoryCode string) (dkd.GPID, error) {
	if !categoryCodeRe.MatchString(categoryCode) {
		return "", fmt.Errorf("catalog: invalid categoryCode %q (want [a-z0-9]{2,12})", categoryCode)
	}
	return dkd.NewGPID(fmt.Sprintf("%s%s-%s", dkd.GPIDPrefix, categoryCode, uuidv7New()))
}

// ValidateGPID checks the full frozen shape GP-{categoryCode}-{uuid7}.
func ValidateGPID(s string) error {
	if _, err := dkd.NewGPID(s); err != nil {
		return err
	}
	body := s[len(dkd.GPIDPrefix):]
	if len(body) < 36+3 { // at least 2-char code + '-' + uuid
		return fmt.Errorf("catalog: gpid too short: %q", s)
	}
	u := body[len(body)-36:]
	if !uuid7Re.MatchString(u) {
		return fmt.Errorf("catalog: gpid body is not a uuidv7: %q", s)
	}
	code := body[:len(body)-37] // strip "-{uuid}"
	if !categoryCodeRe.MatchString(code) {
		return fmt.Errorf("catalog: gpid categoryCode invalid: %q", s)
	}
	return nil
}
