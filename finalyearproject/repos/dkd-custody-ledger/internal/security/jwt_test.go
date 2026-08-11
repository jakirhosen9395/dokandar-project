package security

import (
	"errors"
	"net/http"
	"net/http/httptest"
	"testing"
)

type fakeVerifier struct{ err error }

func (f fakeVerifier) Verify(string) error { return f.err }

// base64url payload of {"sub":"u"} — a structurally valid JWT middle segment.
const tokenSubU = "x.eyJzdWIiOiJ1In0.y"

func serve(j *JWT, authHeader string) *Claims {
	var got *Claims
	h := j.Optional()(http.HandlerFunc(func(_ http.ResponseWriter, r *http.Request) {
		got = ClaimsFrom(r.Context())
	}))
	req := httptest.NewRequest(http.MethodGet, "/", nil)
	if authHeader != "" {
		req.Header.Set("Authorization", authHeader)
	}
	h.ServeHTTP(httptest.NewRecorder(), req)
	return got
}

func TestOptionalAttachesClaimsWithValidVerifier(t *testing.T) {
	got := serve(New("iss", fakeVerifier{nil}), "Bearer "+tokenSubU)
	if got == nil || got.Sub != "u" {
		t.Fatalf("claims not attached: %+v", got)
	}
}

// H3: a nil Verifier must NEVER trust a token (fail closed).
func TestOptionalNilVerifierAttachesNothing(t *testing.T) {
	if got := serve(New("iss", nil), "Bearer "+tokenSubU); got != nil {
		t.Fatalf("nil Verifier must not attach claims, got %+v", got)
	}
}

func TestOptionalRejectsWhenVerifyFails(t *testing.T) {
	if got := serve(New("iss", fakeVerifier{errors.New("bad sig")}), "Bearer "+tokenSubU); got != nil {
		t.Fatalf("verify failure must not attach claims, got %+v", got)
	}
}

func TestOptionalRejectsMalformedTokenAndNoBearer(t *testing.T) {
	if got := serve(New("iss", fakeVerifier{nil}), "Bearer notathreepartjwt"); got != nil {
		t.Fatal("malformed token must not attach claims")
	}
	if got := serve(New("iss", fakeVerifier{nil}), ""); got != nil {
		t.Fatal("anonymous request must not attach claims")
	}
}

func TestHasRole(t *testing.T) {
	c := &Claims{Roles: []string{"admin", "ops"}}
	if !HasRole(c, "admin") {
		t.Fatal("expected admin role")
	}
	if HasRole(c, "root") {
		t.Fatal("unexpected root role")
	}
	if HasRole(nil, "admin") {
		t.Fatal("nil claims must not have roles")
	}
}
