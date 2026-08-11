// Package auth verifies the access JWT issued by dokandar-auth. RS256
// public-key verification — Profile never holds the private key.
package auth

import (
	"context"
	"crypto/rsa"
	"encoding/base64"
	"errors"
	"fmt"
	"net/http"
	"strings"

	"github.com/golang-jwt/jwt/v5"
)

type ctxKey int

const (
	ctxUserID ctxKey = iota
	ctxRole
)

type Verifier struct {
	pubKey *rsa.PublicKey
	issuer string
}

// NewVerifier decodes a base64-encoded RSA public key PEM (the same form
// dokandar-auth emits as JWT_PUBLIC_KEY_B64) and prepares it for verifying.
func NewVerifier(b64PEM, issuer string) (*Verifier, error) {
	if b64PEM == "" {
		return nil, errors.New("JWT_PUBLIC_KEY_B64 is empty")
	}
	pemBytes, err := base64.StdEncoding.DecodeString(b64PEM)
	if err != nil {
		return nil, fmt.Errorf("public key b64 decode: %w", err)
	}
	k, err := jwt.ParseRSAPublicKeyFromPEM(pemBytes)
	if err != nil {
		return nil, fmt.Errorf("public key parse: %w", err)
	}
	return &Verifier{pubKey: k, issuer: issuer}, nil
}

// Middleware enforces a valid Bearer token on a route subtree. Sets
// (user_id, role) on the request context for handler use.
func (v *Verifier) Middleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		hdr := r.Header.Get("Authorization")
		if !strings.HasPrefix(hdr, "Bearer ") {
			writeAuthError(w, r, 401, "token_missing", "Missing Authorization: Bearer header")
			return
		}
		raw := strings.TrimPrefix(hdr, "Bearer ")
		tok, err := jwt.Parse(raw, func(t *jwt.Token) (any, error) {
			if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
				return nil, fmt.Errorf("unexpected signing method: %v", t.Header["alg"])
			}
			return v.pubKey, nil
		}, jwt.WithIssuer(v.issuer), jwt.WithExpirationRequired())
		if err != nil {
			if errors.Is(err, jwt.ErrTokenExpired) {
				writeAuthError(w, r, 401, "token_expired", "Access token has expired (use /refresh)")
			} else {
				writeAuthError(w, r, 401, "token_invalid", "Invalid access token ("+err.Error()+")")
			}
			return
		}
		claims, _ := tok.Claims.(jwt.MapClaims)
		sub, _ := claims["sub"].(string)
		role, _ := claims["role"].(string)
		if sub == "" {
			writeAuthError(w, r, 401, "token_invalid", "Token missing sub claim")
			return
		}
		ctx := context.WithValue(r.Context(), ctxUserID, sub)
		ctx = context.WithValue(ctx, ctxRole, role)
		next.ServeHTTP(w, r.WithContext(ctx))
	})
}

// UserID returns the subject claim placed on ctx by the middleware.
func UserID(ctx context.Context) (string, bool) {
	v, ok := ctx.Value(ctxUserID).(string)
	return v, ok && v != ""
}

// Role returns the role claim placed on ctx by the middleware.
func Role(ctx context.Context) string {
	v, _ := ctx.Value(ctxRole).(string)
	return v
}

func writeAuthError(w http.ResponseWriter, r *http.Request, status int, code, msg string) {
	rid := r.Header.Get("X-Request-Id")
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_, _ = w.Write([]byte(fmt.Sprintf(
		"{\n  \"error\": {\n    \"code\": \"%s\",\n    \"message\": \"%s\",\n    \"request_id\": \"%s\"\n  }\n}\n",
		code, msg, rid,
	)))
}
