package security

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
)

var errMalformedToken = errors.New("malformed token")

// JWT provides authentication (bearer extraction + claims parsing) and an authorization helper.
// Signature verification is delegated to a Verifier (the integration point for the platform JWKS).
type JWT struct {
	Issuer   string
	Verifier Verifier
}

type Verifier interface {
	Verify(token string) error
}

// Claims is the minimal claim set the platform issues (see dkd-platform-libs JwtClaims).
type Claims struct {
	Sub     string   `json:"sub"`
	KycTier string   `json:"kyc_tier"`
	Roles   []string `json:"roles"`
	Cid     string   `json:"cid"`
}

func New(issuer string, v Verifier) *JWT { return &JWT{Issuer: issuer, Verifier: v} }

func parse(token string) (*Claims, error) {
	parts := strings.Split(token, ".")
	if len(parts) != 3 {
		return nil, errMalformedToken
	}
	payload, err := base64.RawURLEncoding.DecodeString(parts[1])
	if err != nil {
		return nil, err
	}
	var c Claims
	if err := json.Unmarshal(payload, &c); err != nil {
		return nil, err
	}
	return &c, nil
}

type claimsKey struct{}

// Optional attaches claims ONLY when a Verifier is configured AND the token both parses and its
// signature verifies. With a nil Verifier (no JWKS wired) NO token is ever trusted — an
// unsigned/unverified bearer must never populate claims. This service is the reference Kafka
// consumer for the platform; the auth pattern here is copied downstream, so it must fail closed.
// Health endpoints stay public regardless (anonymous traffic passes through untouched).
func (j *JWT) Optional() func(http.Handler) http.Handler {
	return func(next http.Handler) http.Handler {
		return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
			if tok := bearer(r); tok != "" && j.Verifier != nil {
				if c, err := parse(tok); err == nil && j.Verifier.Verify(tok) == nil {
					next.ServeHTTP(w, r.WithContext(withClaims(r, c)))
					return
				}
			}
			next.ServeHTTP(w, r)
		})
	}
}

// HasRole is the authorization helper (RBAC). Pair with the platform PDP for ABAC.
func HasRole(c *Claims, role string) bool {
	if c == nil {
		return false
	}
	for _, r := range c.Roles {
		if r == role {
			return true
		}
	}
	return false
}

func bearer(r *http.Request) string {
	h := r.Header.Get("Authorization")
	if strings.HasPrefix(h, "Bearer ") {
		return strings.TrimPrefix(h, "Bearer ")
	}
	return ""
}

func withClaims(r *http.Request, c *Claims) context.Context {
	return context.WithValue(r.Context(), claimsKey{}, c)
}

// ClaimsFrom returns the authenticated claims attached by Optional, if any.
func ClaimsFrom(ctx context.Context) *Claims {
	c, _ := ctx.Value(claimsKey{}).(*Claims)
	return c
}
