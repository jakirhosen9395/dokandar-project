// Package auth is RS256 verify-only (10-wallet never mints JWTs — only 01-auth
// does). It pins algorithms:["RS256"], rejecting alg:none / HS256, and enforces
// the shared INTERNAL_SERVICE_TOKEN (constant-time) on east-west routes.
package auth

import (
	"crypto/rsa"
	"crypto/subtle"
	"encoding/base64"
	"errors"
	"fmt"
	"strings"

	"github.com/gofiber/fiber/v3"
	"github.com/golang-jwt/jwt/v5"
)

type Verifier struct {
	pub      *rsa.PublicKey
	issuer   string
	intToken string
}

// NewVerifier parses auth's PUBLIC key (base64-encoded PEM). An empty key is
// tolerated for dev (RequireUser then rejects every token with missing_token).
func NewVerifier(jwtPubKeyB64, issuer, internalToken string) (*Verifier, error) {
	v := &Verifier{issuer: issuer, intToken: internalToken}
	if jwtPubKeyB64 == "" {
		return v, nil
	}
	raw, err := base64.StdEncoding.DecodeString(jwtPubKeyB64)
	if err != nil {
		return nil, fmt.Errorf("jwt pub b64: %w", err)
	}
	pub, err := jwt.ParseRSAPublicKeyFromPEM(raw)
	if err != nil {
		return nil, fmt.Errorf("parse rsa pub: %w", err)
	}
	v.pub = pub
	return v, nil
}

// RequireUser is the customer-JWT gate. Any failure → 401 missing_token (the
// wallet does not distinguish token_missing vs token_invalid; see smoke brief).
func (v *Verifier) RequireUser() fiber.Handler {
	return func(c fiber.Ctx) error {
		claims, err := v.parseBearer(c)
		if err != nil {
			return unauthorized(c, "missing_token", err.Error())
		}
		c.Locals(localsUserKey, claims)
		return c.Next()
	}
}

// RequireInternalToken gates east-west routes on x-internal-token. Compared
// constant-time. When the token is unset (dev), the guard is bypassed — this
// asymmetry vs the fail-closed gRPC interceptor is intentional (the smoke
// relies on it).
func (v *Verifier) RequireInternalToken() fiber.Handler {
	return func(c fiber.Ctx) error {
		if v.intToken == "" {
			return c.Next() // dev bypass
		}
		got := c.Get("x-internal-token")
		if subtle.ConstantTimeCompare([]byte(got), []byte(v.intToken)) != 1 {
			return unauthorized(c, "unauthorized", "x-internal-token missing or invalid")
		}
		return c.Next()
	}
}

const localsUserKey = "user"

// UserClaims returns the verified MapClaims stashed by RequireUser.
func UserClaims(c fiber.Ctx) (jwt.MapClaims, bool) {
	v := c.Locals(localsUserKey)
	claims, ok := v.(jwt.MapClaims)
	return claims, ok
}

func (v *Verifier) parseBearer(c fiber.Ctx) (jwt.MapClaims, error) {
	if v.pub == nil {
		return nil, errors.New("JWT not configured")
	}
	h := c.Get("Authorization")
	if !strings.HasPrefix(strings.ToLower(h), "bearer ") {
		return nil, errors.New("bearer token required")
	}
	tok := strings.TrimSpace(h[len("Bearer "):])
	parsed, err := jwt.Parse(tok, func(t *jwt.Token) (any, error) {
		// Pin RS256 — reject alg:none / HS256 / any non-RSA signing method.
		if _, ok := t.Method.(*jwt.SigningMethodRSA); !ok {
			return nil, errors.New("unexpected signing method")
		}
		return v.pub, nil
	}, jwt.WithIssuer(v.issuer), jwt.WithExpirationRequired(), jwt.WithValidMethods([]string{"RS256"}))
	if err != nil || !parsed.Valid {
		return nil, errors.New("invalid or expired token")
	}
	claims, ok := parsed.Claims.(jwt.MapClaims)
	if !ok {
		return nil, errors.New("invalid claims")
	}
	return claims, nil
}

func unauthorized(c fiber.Ctx, code, msg string) error {
	rid, _ := c.Locals("request_id").(string)
	return c.Status(fiber.StatusUnauthorized).JSON(fiber.Map{
		"error": fiber.Map{"code": code, "message": msg, "request_id": rid},
	})
}
