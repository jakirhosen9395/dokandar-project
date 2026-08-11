// Package custody implements Context #3 — the R1 SOLE WRITER of provenance truth.
// This file is the hand-rolled CustodyHash Specification v2 (the SDK's provenance.go is a
// stub at the pinned v1.3.0): a deterministic RFC-8785-subset canonical JSON serializer
// (rules R1–R9) and the SHA-256 event-hash/chain primitives. All five runtimes must produce
// byte-identical output for the published test vector.
package custody

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

// CanonicalJSON serializes v per CustodyHash Spec v2 rules R1–R9:
// R2 null/absent omission (object members only), R3 lexicographic UTF-8 key order at every
// depth, R4 no whitespace, R5 UTF-8 strings without \uXXXX for code points < U+0080,
// R6 integers as plain decimal, R7 lowercase booleans, R8 arrays in declaration order,
// R9 recursive application.
func CanonicalJSON(v any) ([]byte, error) {
	var buf bytes.Buffer
	if err := writeCanonical(&buf, v); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

func writeCanonical(buf *bytes.Buffer, v any) error {
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
			if err := writeString(buf, k); err != nil {
				return err
			}
			buf.WriteByte(':')
			if err := writeCanonical(buf, x[k]); err != nil {
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
			if err := writeCanonical(buf, el); err != nil {
				return err
			}
		}
		buf.WriteByte(']')
		return nil
	case string:
		return writeString(buf, x)
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
		// round-trip. Integral floats re-encode as R6 integers; anything else is rejected —
		// the spec defines no float encoding and money/time are int64 by platform law.
		if x == math.Trunc(x) && math.Abs(x) <= 1<<53 {
			buf.WriteString(strconv.FormatInt(int64(x), 10))
			return nil
		}
		return fmt.Errorf("custody: non-integral number %v has no canonical encoding (R6)", x)
	default:
		return fmt.Errorf("custody: type %T has no canonical encoding", v)
	}
}

// writeString emits a JSON string in UTF-8 without HTML escaping and without \uXXXX escapes
// for code points below U+0080 except the mandatory control/quote/backslash escapes (R5).
func writeString(buf *bytes.Buffer, s string) error {
	var tmp bytes.Buffer
	enc := json.NewEncoder(&tmp)
	enc.SetEscapeHTML(false)
	if err := enc.Encode(s); err != nil {
		return fmt.Errorf("custody: string encode: %w", err)
	}
	b := tmp.Bytes()
	buf.Write(bytes.TrimRight(b, "\n"))
	return nil
}

// envelopeExcluded is the set of fields stripped from the canonical payload before hashing.
// Each member is EITHER the hash output itself OR a signature / signing-key reference that
// SIGNS that hash — so including any of them would be circular (a signature cannot commit to a
// value derived from itself, exactly as eventHash cannot). The SIGNED content is therefore the
// full SEMANTIC payload = every field NOT in this set. For a CustodialSigned event that still
// includes agentDid, coSignerDid, ppid, signedAt, previousHash and signingMode — the four-eyes
// facts a tampered payload cannot alter without invalidating both Ed25519 signatures.
//
// DETERMINISM (PL-01, CRITICAL): genesis / transfer / recall / split / merge events and the
// shared cross-language test vectors carry NONE of these fields (coSignerDid appears only on
// CustodialSigned events). Their canonical bytes and digests are therefore byte-for-byte
// UNCHANGED by this set — TV-01 stays ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597.
var envelopeExcluded = map[string]bool{
	"eventHash":            true, // the SHA-256 output — never part of its own preimage
	"signature":            true, // acting-agent Ed25519 signature over eventHash
	"keyId":                true, // acting-agent signing-key reference
	"coSignature":          true, // co-signer Ed25519 signature over the SAME eventHash
	"coKeyId":              true, // co-signer signing-key reference
	"attestationSignature": true, // C3-F2e attestation-authority Ed25519 signature over the POD-ATTEST message (present only on reference-linked attestation transfers; like the other signature slots it signs, and so is excluded from, the hash)
}

// EventHash computes lowercase-hex SHA-256 over the canonical payload with the hash output and
// the signature/keyref envelope (see envelopeExcluded) ALWAYS excluded. previousHash, when the
// event type carries one, must already be present in fields — including the genesis empty
// string "".
func EventHash(fields map[string]any) (string, error) {
	canon := make(map[string]any, len(fields))
	for k, v := range fields {
		if envelopeExcluded[k] {
			continue // the hash and the signatures that sign it are never self-referential
		}
		canon[k] = v
	}
	b, err := CanonicalJSON(canon)
	if err != nil {
		return "", err
	}
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:]), nil
}

// VerifyEvent recomputes the hash of a stored payload (with eventHash present) and reports
// whether it matches the recorded value.
func VerifyEvent(fields map[string]any) (bool, error) {
	recorded, _ := fields["eventHash"].(string)
	if recorded == "" {
		return false, fmt.Errorf("custody: event has no recorded eventHash")
	}
	got, err := EventHash(fields)
	if err != nil {
		return false, err
	}
	return got == recorded, nil
}
