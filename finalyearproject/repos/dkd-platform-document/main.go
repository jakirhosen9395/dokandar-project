// document-svc — DOKANDAR platform #31 (PLAT-02). Evidence/media object store with short-lived signed
// URLs (POD photos, KYC evidence, dispute media). Objects live on a durable volume; access is gated by
// an HMAC-SHA256 signed URL with a hard <=5-minute TTL (the "signed <=5min URLs, PDP-gated" capability).
// The object store engine is unreconciled in canon (RustFS/MinIO, ADR-017); a volume-backed store is
// the canonical-for-now sink, with an S3/RustFS backend as the documented follow-up.
package main

import (
	"context"
	"crypto/hmac"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"io"
	"log/slog"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"strconv"
	"strings"
	"syscall"
	"time"
)

func env(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

var (
	log        = slog.New(slog.NewJSONHandler(os.Stdout, nil))
	dataDir    = env("DKD_DOC_DIR", "/data")
	signingKey = []byte(env("DKD_DOC_SIGNING_KEY", "dev-doc-signing-key-change-me"))
	publicBase = env("DKD_DOC_PUBLIC_BASE", "http://localhost:8124") // base URL the signed link points at
	httpPort   = env("DKD_HTTP_PORT", "8080")
	gitSha     = env("DKD_GIT_SHA", "unknown")
	version    = env("DKD_VERSION", "0.1.0")
	maxTTL     = 5 * time.Minute // FR: signed URLs expire within 5 minutes
	maxBytes   = int64(10 << 20) // 10MB object cap
)

func uuid7ish() string {
	b := make([]byte, 16)
	now := uint64(time.Now().UnixMilli())
	b[0], b[1], b[2], b[3], b[4], b[5] = byte(now>>40), byte(now>>32), byte(now>>24), byte(now>>16), byte(now>>8), byte(now)
	f, _ := os.Open("/dev/urandom")
	if f != nil {
		_, _ = io.ReadFull(f, b[6:])
		_ = f.Close()
	}
	b[6] = (b[6] & 0x0f) | 0x70
	b[8] = (b[8] & 0x3f) | 0x80
	return fmt.Sprintf("%x-%x-%x-%x-%x", b[0:4], b[4:6], b[6:8], b[8:10], b[10:16])
}

// sign returns the HMAC-SHA256 of "<docId>:<exp>" — the signed-URL token.
func sign(docID string, exp int64) string {
	m := hmac.New(sha256.New, signingKey)
	m.Write([]byte(docID + ":" + strconv.FormatInt(exp, 10)))
	return hex.EncodeToString(m.Sum(nil))
}

func signedURL(docID string) string {
	exp := time.Now().Add(maxTTL).UnixMilli()
	return fmt.Sprintf("%s/v1/documents/%s?exp=%d&sig=%s", strings.TrimRight(publicBase, "/"), docID, exp, sign(docID, exp))
}

func writeJSON(w http.ResponseWriter, status int, v any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(v)
}
func problem(w http.ResponseWriter, status int, code, detail string) {
	w.Header().Set("Content-Type", "application/problem+json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(map[string]any{"type": "about:blank", "status": status, "code": code, "detail": detail})
}

func safePath(docID string) (string, bool) {
	// docId is server-minted (uuid7ish); reject anything with a path separator (defense-in-depth).
	if docID == "" || strings.ContainsAny(docID, "/\\.") {
		return "", false
	}
	return filepath.Join(dataDir, docID), true
}

// upload stores the request body as a new object and returns a short-lived signed URL.
func upload(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(io.LimitReader(r.Body, maxBytes+1))
	if err != nil {
		problem(w, http.StatusServiceUnavailable, "dokandar.platform.document.read", err.Error())
		return
	}
	if int64(len(body)) > maxBytes {
		problem(w, http.StatusRequestEntityTooLarge, "dokandar.platform.document.too_large", "object exceeds 10MB")
		return
	}
	if len(body) == 0 {
		problem(w, http.StatusUnprocessableEntity, "dokandar.platform.document.empty", "an empty object cannot be stored")
		return
	}
	docID := uuid7ish()
	p, _ := safePath(docID)
	ct := r.Header.Get("Content-Type")
	if ct == "" {
		ct = "application/octet-stream"
	}
	if err := os.WriteFile(p, body, 0o640); err != nil {
		problem(w, http.StatusServiceUnavailable, "dokandar.platform.document.store", err.Error())
		return
	}
	_ = os.WriteFile(p+".ct", []byte(ct), 0o640)
	writeJSON(w, http.StatusCreated, map[string]any{"success": true, "data": map[string]any{
		"documentId": docID, "size": len(body), "contentType": ct, "signedUrl": signedURL(docID), "expiresInSeconds": int(maxTTL.Seconds()),
	}, "error": nil})
}

// download serves an object ONLY with a valid, unexpired signed URL (constant-time HMAC check).
func download(w http.ResponseWriter, r *http.Request, docID string) {
	q := r.URL.Query()
	exp, _ := strconv.ParseInt(q.Get("exp"), 10, 64)
	sig := q.Get("sig")
	if exp == 0 || sig == "" {
		problem(w, http.StatusForbidden, "dokandar.platform.document.unsigned", "a valid signed URL (exp+sig) is required")
		return
	}
	if time.Now().UnixMilli() > exp {
		problem(w, http.StatusForbidden, "dokandar.platform.document.expired", "the signed URL has expired")
		return
	}
	if !hmac.Equal([]byte(sig), []byte(sign(docID, exp))) {
		problem(w, http.StatusForbidden, "dokandar.platform.document.bad_signature", "signed URL signature is invalid")
		return
	}
	p, ok := safePath(docID)
	if !ok {
		problem(w, http.StatusBadRequest, "dokandar.platform.document.bad_id", "malformed document id")
		return
	}
	data, err := os.ReadFile(p)
	if err != nil {
		problem(w, http.StatusNotFound, "dokandar.platform.document.not_found", "no such document")
		return
	}
	ct, _ := os.ReadFile(p + ".ct")
	if len(ct) == 0 {
		ct = []byte("application/octet-stream")
	}
	w.Header().Set("Content-Type", string(ct))
	w.WriteHeader(http.StatusOK)
	_, _ = w.Write(data)
}

func main() {
	if err := os.MkdirAll(dataDir, 0o750); err != nil {
		log.Warn("data dir not creatable at boot", "dir", dataDir, "err", err.Error())
	}
	mux := http.NewServeMux()
	build := map[string]any{"service": "document-svc", "version": version, "gitSha": gitSha}
	mux.HandleFunc("GET /health", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]any{"success": true, "data": map[string]any{"status": "ok", "service": "document-svc", "gitSha": gitSha}, "error": nil}) })
	mux.HandleFunc("GET /live", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]any{"success": true, "data": map[string]any{"status": "ok"}, "error": nil}) })
	mux.HandleFunc("GET /ready", func(w http.ResponseWriter, _ *http.Request) {
		if _, err := os.Stat(dataDir); err != nil {
			writeJSON(w, 503, map[string]any{"success": false, "data": map[string]any{"status": "degraded", "store": false}, "error": nil})
			return
		}
		writeJSON(w, 200, map[string]any{"success": true, "data": map[string]any{"status": "ready", "store": true}, "error": nil})
	})
	mux.HandleFunc("GET /version", func(w http.ResponseWriter, _ *http.Request) { writeJSON(w, 200, map[string]any{"success": true, "data": build, "error": nil}) })
	mux.HandleFunc("POST /v1/documents", upload)
	mux.HandleFunc("GET /v1/documents/{id}", func(w http.ResponseWriter, r *http.Request) { download(w, r, r.PathValue("id")) })

	srv := &http.Server{Addr: "0.0.0.0:" + httpPort, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	go func() {
		log.Info("document-svc started", "port", httpPort, "dir", dataDir)
		if err := srv.ListenAndServe(); err != nil && err != http.ErrServerClosed {
			log.Error("listen failed", "err", err.Error())
			os.Exit(1)
		}
	}()
	stop := make(chan os.Signal, 1)
	signal.Notify(stop, syscall.SIGINT, syscall.SIGTERM)
	<-stop
	sc, cc := context.WithTimeout(context.Background(), 10*time.Second)
	defer cc()
	_ = srv.Shutdown(sc)
}
