// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// CustodyHash Specification v2 — DM §2 (RFC-8785 subset R1-R9). One of five byte-identical
// runtime implementations; the shared gate is sdk/testvectors/custodyhash_vectors.json (PL-01).
// Ported verbatim from the proven custody-ledger-svc/internal/custody/canonical.go reference.
package dkdplatform

import (
	"bytes"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"math"
	"sort"
	"strconv"
)

// CustodyCanonicalJSON serializes v per CustodyHash Spec v2 rules R1-R9:
// R2 null/absent omission (object members only), R3 lexicographic UTF-8 key order at every
// depth, R4 no whitespace, R5 UTF-8 strings without \uXXXX for code points < U+0080,
// R6 integers as plain decimal, R7 lowercase booleans, R8 arrays in declaration order,
// R9 recursive application.
func CustodyCanonicalJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	if err := writeCustodyCanonical(&buf, v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func writeCustodyCanonical(buf *bytes.Buffer, v any) error {
	switch x := v.(type) {
	case nil:
		return fmt.Errorf("custody: canonical JSON forbids null values outside omitted object members (R2)")
	case map[string]any:
		keys := make([]string, 0, len(x))
		for k, val := range x {
			if val == nil {
				continue // R2: null members are omitted
			}
			keys = append(keys, k)
		}
		sort.Strings(keys) // R3: lexicographic byte order
		buf.WriteByte('{')
		for i, k := range keys {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeCustodyString(buf, k); err != nil {
				return err
			}
			buf.WriteByte(':')
			if err := writeCustodyCanonical(buf, x[k]); err != nil {
				return err
			}
		}
		buf.WriteByte('}')
		return nil
	case []any:
		buf.WriteByte('[') // R8: declaration order, never sorted
		for i, el := range x {
			if i > 0 {
				buf.WriteByte(',')
			}
			if err := writeCustodyCanonical(buf, el); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
		return nil
	case string:
		return writeCustodyString(buf, x)
	case bool:
		if x {
			buf.WriteString("true")
		} else {
			buf.WriteString("false")
		}
		return nil
	case int:
		buf.WriteString(strconv.FormatInt(int64(x), 10))
		return nil
	case int32:
		buf.WriteString(strconv.FormatInt(int64(x), 10))
		return nil
	case int64:
		buf.WriteString(strconv.FormatInt(x, 10)) // R6: plain decimal
		return nil
	case float64:
		// Payloads are built natively with int64; floats appear only after a JSON decode
		// round-trip. Integral floats re-encode as R6 integers; anything else is rejected.
		if x == math.Trunc(x) && math.Abs(x) <= 1<<53 {
			buf.WriteString(strconv.FormatInt(int64(x), 10))
			return nil
		}
		return fmt.Errorf("custody: non-integral number %v has no canonical encoding (R6)", x)
	default:
		return fmt.Errorf("custody: type %T has no canonical encoding", v)
	}
}

// writeCustodyString emits a JSON string in UTF-8 without HTML escaping and without \uXXXX
// escapes for code points below U+0080 except the mandatory control/quote/backslash escapes (R5).
func writeCustodyString(buf *bytes.Buffer, s string) error {
	var tmp bytes.Buffer
	enc := json.NewEncoder(&tmp)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return fmt.Errorf("custody: string encode: %w", err)
	}
	buf.Write(bytes.TrimRight(tmp.Bytes(), "\n"))
	return nil
}

// CustodyEventHash computes lowercase-hex SHA-256 over the canonical payload with "eventHash"
// ALWAYS excluded (it is the output). previousHash, when the event type carries one, must
// already be present in fields — including the genesis empty string "".
func CustodyEventHash(fields map[string]any) (string, error) {
	canon := make(map[string]any, len(fields))
	for k, v := range fields {
		if k == "eventHash" {
			continue // unconditionally excluded from its own canonical payload
		}
		canon[k] = v
	}
	b, err := CustodyCanonicalJSON(canon)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

// CustodyVerifyEvent recomputes the hash of a stored payload (with eventHash present) and
// reports whether it matches the recorded value.
func CustodyVerifyEvent(fields map[string]any) (bool, error) {
	recorded, _ := fields["eventHash"].(string)
	if recorded == "" {
		return false, fmt.Errorf("custody: event has no recorded eventHash")
	}
	got, err := CustodyEventHash(fields)
	if err != nil {
		return false, err
	}
	return got == recorded, nil
}
