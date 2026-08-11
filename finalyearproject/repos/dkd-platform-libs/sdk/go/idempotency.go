// Hand-authored primitive (PL-03). NOT dkdgen output: the Idempotency-Key HTTP
// middleware enforcing canon EF-API-6 on unsafe/money/custody writes —
//   - MISSING key on an unsafe write            -> 400 (malformed)
//   - SAME key + SAME payload (replay)           -> the stored original response
//   - SAME key + DIFFERENT payload               -> 409 (state conflict)
// It is backed by a pluggable IdempotencyStore (the PL-02 inbox / a dedicated
// idem table / an in-memory fake) — no DB is hard-wired here.

package dkdplatform

import (
	"bytes"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"io"
	"net/http"
	"sync"
)

// IdempotencyKeyHeader is the canonical request header (EF-API-6).
const IdempotencyKeyHeader = "Idempotency-Key"

// IdempotencyRecord is the stored original response for a given key, plus the
// hash of the request payload that produced it (to detect a same-key/different-
// payload replay).
type IdempotencyRecord struct {
	PayloadHash string
	Status      int
	Body        []byte
	Headers     map[string]string
}

// IdempotencyStore is the pluggable persistence seam. Lookup reports (record,
// found, error); Save records the first response under a key. A DB-backed store
// implements this over an idem table in the same tx discipline as the PL-02
// inbox; MemIdempotencyStore is the in-memory implementation used in tests.
type IdempotencyStore interface {
	Lookup(ctx context.Context, key string) (IdempotencyRecord, bool, error)
	Save(ctx context.Context, key string, rec IdempotencyRecord) error
}

// MemIdempotencyStore is a goroutine-safe in-memory IdempotencyStore. It is the
// reference/fake implementation — production services supply a durable store.
type MemIdempotencyStore struct {
	mu   sync.Mutex
	data map[string]IdempotencyRecord
}

// NewMemIdempotencyStore constructs an empty in-memory store.
func NewMemIdempotencyStore() *MemIdempotencyStore {
	return &MemIdempotencyStore{data: map[string]IdempotencyRecord{}}
}

func (s *MemIdempotencyStore) Lookup(_ context.Context, key string) (IdempotencyRecord, bool, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	rec, ok := s.data[key]
	return rec, ok, nil
}

func (s *MemIdempotencyStore) Save(_ context.Context, key string, rec IdempotencyRecord) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	if _, exists := s.data[key]; exists {
		return nil // first-writer-wins; a concurrent duplicate is a no-op
	}
	s.data[key] = rec
	return nil
}

// isUnsafeMethod reports whether a method mutates state and therefore requires
// an Idempotency-Key (EF-API-6). GET/HEAD/OPTIONS/TRACE are safe.
func isUnsafeMethod(m string) bool {
	switch m {
	case http.MethodPost, http.MethodPut, http.MethodPatch, http.MethodDelete:
		return true
	default:
		return false
	}
}

// IdempotencyMiddleware wraps a handler with EF-API-6 enforcement backed by the
// given store. Safe methods pass straight through. For an unsafe method it
// requires the Idempotency-Key header, replays the stored response on a
// same-payload retry, and returns 409 on a same-key/different-payload clash.
func IdempotencyMiddleware(store IdempotencyStore) func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if !isUnsafeMethod(r.Method) {
				next.ServeHTTP(w, r)
				return
			}
			key := r.Header.Get(IdempotencyKeyHeader)
			if key == "" {
				WriteProblem(w, NewMalformedError(
					"dokandar.platform.idempotency.missing_key",
					"Idempotency-Key header is required on this request"), 0)
				return
			}

			body, err := io.ReadAll(r.Body)
			if err != nil {
				WriteProblem(w, NewMalformedError(
					"dokandar.platform.idempotency.unreadable_body",
					"request body could not be read"), 0)
				return
			}
			_ = r.Body.Close()
			r.Body = io.NopCloser(bytes.NewReader(body))
			hash := hashPayload(body)

			rec, found, err := store.Lookup(r.Context(), key)
			if err != nil {
				WriteProblem(w, NewUnavailableError(
					"dokandar.platform.idempotency.store_unavailable",
					"idempotency store is unavailable"), 0)
				return
			}
			if found {
				if rec.PayloadHash == hash {
					replay(w, rec)
					return
				}
				WriteProblem(w, NewConflictError(
					"dokandar.platform.idempotency.payload_mismatch",
					"Idempotency-Key reused with a different request payload"), 0)
				return
			}

			rec = IdempotencyRecord{PayloadHash: hash}
			rw := &recordingWriter{ResponseWriter: w, status: http.StatusOK}
			next.ServeHTTP(rw, r)
			rec.Status = rw.status
			rec.Body = rw.body.Bytes()
			rec.Headers = flattenHeaders(rw.Header())
			_ = store.Save(r.Context(), key, rec)
		})
	}
}

func hashPayload(b []byte) string {
	sum := sha256.Sum256(b)
	return hex.EncodeToString(sum[:])
}

func replay(w http.ResponseWriter, rec IdempotencyRecord) {
	for k, v := range rec.Headers {
		w.Header().Set(k, v)
	}
	w.Header().Set("Idempotency-Replayed", "true")
	if rec.Status == 0 {
		rec.Status = http.StatusOK
	}
	w.WriteHeader(rec.Status)
	_, _ = w.Write(rec.Body)
}

func flattenHeaders(h http.Header) map[string]string {
	out := make(map[string]string, len(h))
	for k := range h {
		out[k] = h.Get(k)
	}
	return out
}

// recordingWriter captures the handler's status + body so the original response
// can be stored and later replayed.
type recordingWriter struct {
	http.ResponseWriter
	status      int
	body        bytes.Buffer
	wroteHeader bool
}

func (rw *recordingWriter) WriteHeader(code int) {
	if rw.wroteHeader {
		return
	}
	rw.status = code
	rw.wroteHeader = true
	rw.ResponseWriter.WriteHeader(code)
}

func (rw *recordingWriter) Write(b []byte) (int, error) {
	if !rw.wroteHeader {
		rw.WriteHeader(http.StatusOK)
	}
	rw.body.Write(b)
	return rw.ResponseWriter.Write(b)
}
