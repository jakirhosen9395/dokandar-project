// Package jwks is the gateway's RS256 verify-only JWT validator. The gateway
// never mints tokens (only 01-auth does) — it verifies Bearer tokens against
// 01-auth's PUBLIC keys, fetched as a JWKS document and cached in-process for a
// 5-minute TTL (architecture.md §3/§12/§16-c).
//
// Two key sources, JWKS primary:
//   - JWKS (primary): GET cfg.JWKSURL → {"keys":[{kty,kid,use,alg,n,e}]} (the
//     exact RFC 7517 shape 01-auth/app/domain/tokens.py emits). n and e are
//     unpadded base64url big-endian ints → decoded with base64.RawURLEncoding.
//   - Static key (fallback): when cfg.JWKSURL == "", cfg.PublicKeyB64 (a
//     base64-encoded PEM, the same JWT_PUBLIC_KEY_B64 every other verify-only
//     service consumes) is parsed once into the single verifier key — decoded
//     with base64.StdEncoding then jwt.ParseRSAPublicKeyFromPEM (matching
//     10-wallet/internal/auth/jwt.go). The two codecs are DIFFERENT: do not
//     conflate them.
//
// Security invariants (architecture.md §12/§16-c):
//   - algorithms allowlist PINNED to RS256 (cfg.Algorithms) — reject alg:none,
//     HS256, and the RSA/HMAC alg-confusion bypass. Enforced TWICE: a keyfunc
//     that type-asserts *jwt.SigningMethodRSA AND jwt.WithValidMethods.
//   - enforce iss (cfg.Issuer) + exp (required). nbf is validated automatically
//     by golang-jwt only when the claim is present (01-auth omits it). aud is
//     enforced ONLY when cfg.Audience != "" (else WithAudience would 401 every
//     real token, which carries no aud).
//
// Resilience (architecture.md §13/§16-a): a JWKS fetch failure NEVER fails boot
// and NEVER 5xx's a request — the cached key set keeps serving for the rest of
// the 5-min TTL; only gateway_jwks_refresh_total{result:"error"} signals it. The
// single front door must not be pulled from the LB by a 01-auth blip.
package jwks

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"log/slog"
	"math/big"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/golang-jwt/jwt/v5"

	"github.com/dokandar/dokandar-gateway/internal/observability"
)

// Config is the verifier's configuration. The field names + CacheTTL's
// time.Duration type are the FIXED seam main.go (cmd/gateway/main.go) constructs
// against — do not rename or retype.
type Config struct {
	// JWKSURL is 01-auth's JWKS endpoint (= http://<auth>/api/v1/auth/jwks).
	// Empty → static-key fallback (PublicKeyB64).
	JWKSURL string
	// CacheTTL is the in-process JWKS cache lifetime (5 min per the contract).
	CacheTTL time.Duration
	// Algorithms is the PINNED signing-alg allowlist (["RS256"]).
	Algorithms []string
	// Issuer is the required iss claim (dokandar-auth).
	Issuer string
	// Audience, when non-empty, is the required aud claim.
	Audience string
	// PublicKeyB64 is the base64-encoded PEM fallback key (JWT_PUBLIC_KEY_B64),
	// used only when JWKSURL is empty.
	PublicKeyB64 string
}

// Verifier validates Bearer tokens against a cached JWKS key set (keyed by kid)
// or, in fallback mode, a single static key. Thread-safe.
type Verifier struct {
	cfg    Config
	client *http.Client

	// static is the single fallback key (nil unless JWKSURL == ""). When set,
	// kid is ignored and every token verifies against it.
	static *rsa.PublicKey

	mu        sync.RWMutex
	keys      map[string]*rsa.PublicKey // kid → public key (JWKS mode)
	fetchedAt time.Time                 // last SUCCESSFUL refresh

	// refreshing single-flights the lazy TTL refresh so a down 01-auth is not
	// hammered by one fetch per request (others serve the stale cache).
	refreshing atomic.Bool
}

// jwksDocument is the RFC 7517 shape 01-auth serves.
type jwksDocument struct {
	Keys []jwkEntry `json:"keys"`
}

type jwkEntry struct {
	Kty string `json:"kty"`
	Kid string `json:"kid"`
	Use string `json:"use"`
	Alg string `json:"alg"`
	N   string `json:"n"` // modulus, unpadded base64url
	E   string `json:"e"` // exponent, unpadded base64url
}

// NewVerifier builds the verifier. In static-fallback mode (JWKSURL == "") it
// parses PublicKeyB64 once — a present-but-malformed key is the only fatal error
// (a misconfiguration we must surface, not paper over). In JWKS mode it warms
// the cache with a SHORT-bounded fetch, but a fetch failure is NON-FATAL: the
// gateway must boot even when 01-auth is down (architecture.md §13/§14/§16-a).
func NewVerifier(ctx context.Context, cfg Config) (*Verifier, error) {
	if len(cfg.Algorithms) == 0 {
		cfg.Algorithms = []string{"RS256"}
	}
	v := &Verifier{
		cfg:    cfg,
		client: &http.Client{Timeout: 3 * time.Second},
		keys:   map[string]*rsa.PublicKey{},
	}

	// ---- static-key fallback (no JWKS endpoint configured) ----
	if strings.TrimSpace(cfg.JWKSURL) == "" {
		if strings.TrimSpace(cfg.PublicKeyB64) == "" {
			// Neither source configured: boot DEGRADED. Public routes serve;
			// Bearer routes 401 (no key to verify against). The front-door
			// philosophy favours booting over failing fast.
			slog.Warn("jwks: no JWKS_URL and no JWT_PUBLIC_KEY_B64 — bearer routes will 401",
				"name", "gateway.jwks")
			return v, nil
		}
		pub, err := parseStaticPEM(cfg.PublicKeyB64)
		if err != nil {
			// A configured-but-broken key is a real misconfiguration.
			return nil, fmt.Errorf("jwks: static JWT_PUBLIC_KEY_B64 invalid: %w", err)
		}
		v.static = pub
		slog.Info("jwks: static-key fallback active (no JWKS_URL)", "name", "gateway.jwks")
		return v, nil
	}

	// ---- JWKS mode: warm the cache, but never fail boot on a fetch error ----
	warmCtx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	if err := v.refresh(warmCtx); err != nil {
		slog.Warn("jwks: initial fetch failed (booting; will serve once 01-auth reachable)",
			"name", "gateway.jwks", "url", cfg.JWKSURL, "err", err.Error())
		// Non-fatal — return the verifier with an empty key set.
	}
	return v, nil
}

// parseStaticPEM decodes a base64-encoded PEM (StdEncoding) into an RSA public
// key — the same path 10-wallet uses for its static verify-only key.
func parseStaticPEM(b64 string) (*rsa.PublicKey, error) {
	raw, err := base64.StdEncoding.DecodeString(b64)
	if err != nil {
		return nil, fmt.Errorf("base64: %w", err)
	}
	pub, err := jwt.ParseRSAPublicKeyFromPEM(raw)
	if err != nil {
		return nil, fmt.Errorf("parse rsa pem: %w", err)
	}
	return pub, nil
}

// refresh fetches the JWKS document and atomically swaps the kid→key map.
// On success: gateway_jwks_refresh_total{result:"ok"} + fetchedAt updated.
// On failure: gateway_jwks_refresh_total{result:"error"} + the existing cache is
// LEFT INTACT (serve-from-cache) and the error is returned to the caller.
func (v *Verifier) refresh(ctx context.Context) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, v.cfg.JWKSURL, nil)
	if err != nil {
		observability.GatewayJWKSRefreshTotal.WithLabelValues(observability.ServiceVal, "error").Inc()
		return err
	}
	req.Header.Set("Accept", "application/json")

	resp, err := v.client.Do(req)
	if err != nil {
		observability.GatewayJWKSRefreshTotal.WithLabelValues(observability.ServiceVal, "error").Inc()
		return err
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusOK {
		observability.GatewayJWKSRefreshTotal.WithLabelValues(observability.ServiceVal, "error").Inc()
		return fmt.Errorf("jwks: status %d", resp.StatusCode)
	}

	body, err := io.ReadAll(io.LimitReader(resp.Body, 1<<20)) // 1 MiB ceiling
	if err != nil {
		observability.GatewayJWKSRefreshTotal.WithLabelValues(observability.ServiceVal, "error").Inc()
		return err
	}

	var doc jwksDocument
	if err := json.Unmarshal(body, &doc); err != nil {
		observability.GatewayJWKSRefreshTotal.WithLabelValues(observability.ServiceVal, "error").Inc()
		return fmt.Errorf("jwks: decode: %w", err)
	}

	parsed := map[string]*rsa.PublicKey{}
	for _, k := range doc.Keys {
		if !strings.EqualFold(k.Kty, "RSA") {
			continue // only RSA keys are usable for RS256
		}
		pub, err := jwkToRSA(k)
		if err != nil {
			slog.Warn("jwks: skipping unparseable key", "name", "gateway.jwks", "kid", k.Kid, "err", err.Error())
			continue
		}
		parsed[k.Kid] = pub
	}
	if len(parsed) == 0 {
		observability.GatewayJWKSRefreshTotal.WithLabelValues(observability.ServiceVal, "error").Inc()
		return errors.New("jwks: document contained no usable RSA keys")
	}

	v.mu.Lock()
	v.keys = parsed
	v.fetchedAt = time.Now()
	v.mu.Unlock()

	observability.GatewayJWKSRefreshTotal.WithLabelValues(observability.ServiceVal, "ok").Inc()
	return nil
}

// jwkToRSA reconstructs an *rsa.PublicKey from a JWK's n/e. n and e are unpadded
// base64url big-endian integers (RawURLEncoding) — NOT StdEncoding/URLEncoding,
// which expect padding and would fail on every 01-auth key.
func jwkToRSA(k jwkEntry) (*rsa.PublicKey, error) {
	nBytes, err := base64.RawURLEncoding.DecodeString(k.N)
	if err != nil {
		return nil, fmt.Errorf("decode n: %w", err)
	}
	eBytes, err := base64.RawURLEncoding.DecodeString(k.E)
	if err != nil {
		return nil, fmt.Errorf("decode e: %w", err)
	}
	if len(nBytes) == 0 || len(eBytes) == 0 {
		return nil, errors.New("empty modulus or exponent")
	}
	e := new(big.Int).SetBytes(eBytes).Int64()
	if e <= 0 || e > int64(^uint32(0)) {
		return nil, fmt.Errorf("exponent out of range: %d", e)
	}
	return &rsa.PublicKey{
		N: new(big.Int).SetBytes(nBytes),
		E: int(e),
	}, nil
}

// keyForToken is the jwt.Keyfunc (func(*jwt.Token) (any, error)) passed to
// jwt.Parse. It returns the verifier key for a token's kid header. In
// static-fallback mode kid is ignored and the single key is returned. In JWKS
// mode the cache is refreshed lazily when the TTL has elapsed (serve-from-cache
// on a failed refresh), then the kid is looked up. The return type is `any` to
// satisfy jwt.Keyfunc — Go has no covariance on function return types.
func (v *Verifier) keyForToken(t *jwt.Token) (any, error) {
	// Defense-in-depth (the WithValidMethods option also enforces this): pin RSA.
	if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
		return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
	}

	if v.static != nil {
		return v.static, nil
	}

	v.maybeRefresh()

	kid, _ := t.Header["kid"].(string)
	v.mu.RLock()
	defer v.mu.RUnlock()
	if kid != "" {
		if pub, ok := v.keys[kid]; ok {
			return pub, nil
		}
		return nil, fmt.Errorf("no key for kid %q", kid)
	}
	// No kid in the token header: if exactly one key is cached, use it.
	if len(v.keys) == 1 {
		for _, pub := range v.keys {
			return pub, nil
		}
	}
	return nil, errors.New("token has no kid and key set is ambiguous")
}

// maybeRefresh refreshes the JWKS cache when the 5-min TTL has elapsed. A failed
// refresh is swallowed here (the metric + log fire inside refresh); the stale
// cache keeps serving (architecture.md §13). Refresh runs at most one at a time.
func (v *Verifier) maybeRefresh() {
	v.mu.RLock()
	stale := time.Since(v.fetchedAt) >= v.cfg.CacheTTL
	v.mu.RUnlock()
	if !stale {
		return
	}
	if !v.refreshing.CompareAndSwap(false, true) {
		return // another goroutine is already refreshing; serve the cache
	}
	defer v.refreshing.Store(false)

	// Re-check under the guard — a concurrent refresher may have just finished.
	v.mu.RLock()
	stale = time.Since(v.fetchedAt) >= v.cfg.CacheTTL
	v.mu.RUnlock()
	if !stale {
		return
	}

	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	_ = v.refresh(ctx) // failure → serve-from-cache; metric already incremented
}

// JWKSHealth is the diagnostic surface ops/ops.go's /health consumes (via its
// optional jwksHealther interface — this is duck-typed, ops does not import this
// package). It reports the in-process key-cache state. It is DIAGNOSTIC ONLY and
// must NEVER flip /ready (architecture.md §8.2): the verifier always serves from
// the 5-min cache, so a transient 01-auth fetch blip is not an outage.
//
//   - static-fallback mode → always ok, detail "static-key".
//   - JWKS mode with keys cached → ok, detail noting key count + cache age.
//   - JWKS mode with an empty cache (never reached 01-auth) → not-ok, "no-keys"
//     (bearer routes will 401 until a refresh succeeds — surfaced, not gating).
func (v *Verifier) JWKSHealth() (ok bool, detail string) {
	if v.static != nil {
		return true, "static-key"
	}
	v.mu.RLock()
	n := len(v.keys)
	fetched := v.fetchedAt
	v.mu.RUnlock()
	if n == 0 {
		return false, "no-keys (01-auth unreachable since boot)"
	}
	age := time.Since(fetched).Truncate(time.Second)
	return true, fmt.Sprintf("cached %d key(s), age %s", n, age)
}

// Verify validates a bare token string (no "Bearer " prefix — the auth-gate
// strips that) and returns the verified claims. The algorithms allowlist is
// pinned (keyfunc RSA-assert + WithValidMethods); iss + exp are required; aud is
// enforced only when configured; nbf is validated only if the token carries it.
func (v *Verifier) Verify(tokenString string) (jwt.MapClaims, error) {
	tokenString = strings.TrimSpace(tokenString)
	if tokenString == "" {
		return nil, errors.New("empty token")
	}

	opts := []jwt.ParserOption{
		jwt.WithValidMethods(v.cfg.Algorithms),
		jwt.WithExpirationRequired(),
	}
	if v.cfg.Issuer != "" {
		opts = append(opts, jwt.WithIssuer(v.cfg.Issuer))
	}
	if v.cfg.Audience != "" {
		opts = append(opts, jwt.WithAudience(v.cfg.Audience))
	}

	parsed, err := jwt.Parse(tokenString, v.keyForToken, opts...)
	if err != nil {
		return nil, err
	}
	if !parsed.Valid {
		return nil, errors.New("token invalid")
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		return nil, errors.New("unexpected claims type")
	}
	return claims, nil
}
