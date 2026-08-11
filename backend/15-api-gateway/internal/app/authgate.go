package app

import (
	"net/http"
	"strings"

	"github.com/golang-jwt/jwt/v5"
	"github.com/labstack/echo/v4"

	"github.com/dokandar/dokandar-gateway/internal/jwks"
)

// ClaimsKey is the echo.Context key under which RequireBearer stashes the
// verified jwt.MapClaims so a downstream BFF/handler can read the principal
// (sub/role) without re-parsing the token.
const ClaimsKey = "jwt_claims"

// ClaimsOf returns the verified claims stashed by RequireBearer (nil, false on
// a public route or before the gate ran).
func ClaimsOf(c echo.Context) (jwt.MapClaims, bool) {
	v, ok := c.Get(ClaimsKey).(jwt.MapClaims)
	return v, ok
}

// PrincipalOf returns the token subject (sub claim) for the access log /
// rate-limit principal key, or "" when unauthenticated.
func PrincipalOf(c echo.Context) string {
	if claims, ok := ClaimsOf(c); ok {
		if sub, ok := claims["sub"].(string); ok {
			return sub
		}
	}
	return ""
}

// RequireBearer is the per-route Bearer-auth gate. It extracts the Authorization
// header, requires a "Bearer <token>" scheme, verifies the token via the JWKS
// verifier (RS256 pinned; iss/exp enforced; aud if configured), and on success
// stashes the claims under ClaimsKey for downstream handlers. ANY failure →
// 401 token_invalid via the standard error envelope.
//
// It is returned as an echo.MiddlewareFunc so main/proxy can attach it to a
// Route.Auth field on Bearer routes and leave it nil on public routes (the
// per-route public-vs-Bearer toggle — architecture.md §5/§12).
//
// Lives in package app (not jwks) so the jwks package stays Echo-free: the
// import graph is app→jwks, proxy→app+jwks, jwks→neither — no cycle.
func RequireBearer(v *jwks.Verifier) echo.MiddlewareFunc {
	return func(next echo.HandlerFunc) echo.HandlerFunc {
		return func(c echo.Context) error {
			token, err := bearerToken(c)
			if err != nil {
				return unauthorized(c, err.Error())
			}
			claims, err := v.Verify(token)
			if err != nil {
				// Never leak the verifier's internal reason to the caller
				// (it can carry alg/kid/clock detail); the access log + APM
				// keep the diagnostic. The client gets a stable token_invalid.
				return unauthorized(c, "token verification failed")
			}
			c.Set(ClaimsKey, claims)
			return next(c)
		}
	}
}

// bearerToken pulls the bare token out of the Authorization header, requiring
// the "Bearer " scheme (case-insensitive). Returns a client-safe reason string.
func bearerToken(c echo.Context) (string, error) {
	h := strings.TrimSpace(c.Request().Header.Get(echo.HeaderAuthorization))
	if h == "" {
		return "", errAuthMissing
	}
	if !strings.HasPrefix(strings.ToLower(h), "bearer ") {
		return "", errAuthScheme
	}
	tok := strings.TrimSpace(h[len("Bearer "):])
	if tok == "" {
		return "", errAuthMissing
	}
	return tok, nil
}

// unauthorized renders the contract 401 token_invalid error envelope. The
// detail message is a client-safe reason; AccessLogAndMetrics still records the
// 401 in RED metrics + the access log.
func unauthorized(c echo.Context, reason string) error {
	return ErrorEnvelope(c, http.StatusUnauthorized, "token_invalid", reason, nil)
}

// Client-safe auth-failure reasons (no token internals).
var (
	errAuthMissing = authReason("authorization bearer token required")
	errAuthScheme  = authReason("authorization scheme must be Bearer")
)

type authReason string

func (e authReason) Error() string { return string(e) }
