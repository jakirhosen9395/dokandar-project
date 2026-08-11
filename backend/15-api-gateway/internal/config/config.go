// Package config loads the gateway's runtime configuration from discrete env
// vars (rendered by env/init-env.sh). The gateway is the STATELESS edge: no
// Postgres, no Kafka, no outbox — Redis DB 13 is its only datastore (the
// token-bucket rate-limiter). It is verify-only (auth's PUBLIC key / JWKS).
//
// Two kinds of vars are read:
//   - what env/init-env.sh renders TODAY (SERVICE_*, REDIS_*, MONGO_LOG_*,
//     ELASTIC_SEARCH_*, APM_*, JWT_PUBLIC_KEY_B64, JWT_ISSUER) — via envconfig.
//   - the spec/edge vars (JWKS_URL, JWT_AUDIENCE, RATE_LIMIT_*, UPSTREAM_<SVC>,
//     UPSTREAM_READ_TIMEOUT_MS, CORS_ALLOWLIST, TRUSTED_PROXY_CIDRS) — with
//     defaults, so the service boots whether or not they are present.
//
// The Upstreams map is parsed by scanning os.Environ() for UPSTREAM_<SVC>=…
// (envconfig cannot bind a dynamic-keyed map), keyed by the lower-cased <SVC>.
package config

import (
	"fmt"
	"os"
	"strings"

	"github.com/kelseyhightower/envconfig"
	"github.com/redis/go-redis/v9"
)

// Settings holds the full runtime configuration. All exported; the logic agents
// read these fields directly. Defaults match architecture.md §9.
type Settings struct {
	// -- Application / identity --------------------------------------------
	AppEnv      string `envconfig:"APP_ENV" default:"dev"`
	ServiceName string `envconfig:"SERVICE_NAME" default:"15-api-gateway"`
	EnvVersion  string `envconfig:"ENV_VERSION" default:"v1.0.0"`
	Tenant      string `envconfig:"TENANT" default:"local"`
	// SERVICE_PORT is 8080 in-container (the run line maps -p 10015:8080).
	ServicePort int    `envconfig:"SERVICE_PORT" default:"8080"`
	LogLevel    string `envconfig:"LOG_LEVEL" default:"info"`

	// -- Redis (DB 13 — token-bucket rate-limiter only) --------------------
	RedisHost     string `envconfig:"REDIS_HOST"`
	RedisPort     int    `envconfig:"REDIS_PORT" default:"6379"`
	RedisPassword string `envconfig:"REDIS_PASSWORD"`
	// init-env.sh renders RATE_LIMIT_REDIS_DB=13; accept both keys, REDIS_DB wins.
	RedisDB          int `envconfig:"REDIS_DB" default:"13"`
	RateLimitRedisDB int `envconfig:"RATE_LIMIT_REDIS_DB" default:"13"`

	// -- JWT / JWKS (verify-only) ------------------------------------------
	// JWKS is primary; if JWKSURL is empty the static JWTPublicKeyB64 (base64
	// PEM, rendered by init-env.sh) is the fallback verifier key.
	JWKSURL             string `envconfig:"JWKS_URL"`
	JWKSCacheTTLSeconds int    `envconfig:"JWKS_CACHE_TTL_SECONDS" default:"300"`
	JWTAlgorithms       string `envconfig:"JWT_ALGORITHMS" default:"RS256"`
	JWTAudience         string `envconfig:"JWT_AUDIENCE"`
	JWTIssuer           string `envconfig:"JWT_ISSUER" default:"dokandar-auth"`
	JWTPublicKeyB64     string `envconfig:"JWT_PUBLIC_KEY_B64"`

	// -- Rate-limit (token bucket) -----------------------------------------
	RateLimitMax      int `envconfig:"RATE_LIMIT_MAX" default:"120"`
	RateLimitWindowMS int `envconfig:"RATE_LIMIT_WINDOW_MS" default:"1000"`

	// -- Upstreams (verbatim proxy targets) --------------------------------
	// Parsed in Load() from every UPSTREAM_<SVC>=url env var → {auth:url, …}.
	Upstreams             map[string]string `envconfig:"-"`
	UpstreamReadTimeoutMS int               `envconfig:"UPSTREAM_READ_TIMEOUT_MS" default:"5000"`

	// -- CORS + security ---------------------------------------------------
	// Raw CSV from env; parsed lists are CORSAllowlist / TrustedProxyCIDRs.
	CORSAllowlistRaw     string   `envconfig:"CORS_ALLOWLIST"`
	TrustedProxyCIDRsRaw string   `envconfig:"TRUSTED_PROXY_CIDRS"`
	CORSAllowlist        []string `envconfig:"-"`
	TrustedProxyCIDRs    []string `envconfig:"-"`

	// -- Observability sinks -----------------------------------------------
	MongoLogURI           string `envconfig:"MONGO_LOG_URI"`
	MongoLogDB            string `envconfig:"MONGO_LOG_DB" default:"mongo_db_dokandar_application_logs"`
	ElasticSearchURL      string `envconfig:"ELASTIC_SEARCH_URL"`
	ElasticSearchUsername string `envconfig:"ELASTIC_SEARCH_USERNAME"`
	ElasticSearchPassword string `envconfig:"ELASTIC_SEARCH_PASSWORD"`
	APMServerURL          string `envconfig:"APM_SERVER_URL"`
	APMSecretToken        string `envconfig:"APM_SECRET_TOKEN"`
	APMServiceName        string `envconfig:"APM_SERVICE_NAME" default:"15-api-gateway"`
}

// Load reads + validates the environment. SERVICE_NAME must be non-empty
// (fail-fast — the identity block + observability join key depend on it).
func Load() (*Settings, error) {
	s := &Settings{}
	if err := envconfig.Process("", s); err != nil {
		return nil, fmt.Errorf("envconfig: %w", err)
	}
	if strings.TrimSpace(s.ServiceName) == "" {
		return nil, fmt.Errorf("SERVICE_NAME is empty (required for identity block)")
	}
	if s.APMServiceName == "" {
		s.APMServiceName = s.ServiceName
	}

	// init-env.sh renders RATE_LIMIT_REDIS_DB (not REDIS_DB). If REDIS_DB was
	// left at its default but RATE_LIMIT_REDIS_DB was set, honour the latter.
	if _, ok := os.LookupEnv("REDIS_DB"); !ok {
		if _, ok := os.LookupEnv("RATE_LIMIT_REDIS_DB"); ok {
			s.RedisDB = s.RateLimitRedisDB
		}
	}

	s.Upstreams = parseUpstreams(os.Environ())
	s.CORSAllowlist = splitCSV(s.CORSAllowlistRaw)
	s.TrustedProxyCIDRs = splitCSV(s.TrustedProxyCIDRsRaw)
	return s, nil
}

// parseUpstreams scans for UPSTREAM_<SVC>=url (excluding UPSTREAM_READ_TIMEOUT_MS)
// and returns {<svc-lowercased>: url}. e.g. UPSTREAM_AUTH=http://… → {"auth": …}.
func parseUpstreams(environ []string) map[string]string {
	out := map[string]string{}
	for _, kv := range environ {
		eq := strings.IndexByte(kv, '=')
		if eq <= 0 {
			continue
		}
		k, v := kv[:eq], kv[eq+1:]
		if !strings.HasPrefix(k, "UPSTREAM_") {
			continue
		}
		if k == "UPSTREAM_READ_TIMEOUT_MS" {
			continue
		}
		svc := strings.ToLower(strings.TrimPrefix(k, "UPSTREAM_"))
		if svc == "" || strings.TrimSpace(v) == "" {
			continue
		}
		out[svc] = strings.TrimRight(strings.TrimSpace(v), "/")
	}
	return out
}

func splitCSV(raw string) []string {
	if strings.TrimSpace(raw) == "" {
		return nil
	}
	parts := strings.Split(raw, ",")
	out := make([]string, 0, len(parts))
	for _, p := range parts {
		if t := strings.TrimSpace(p); t != "" {
			out = append(out, t)
		}
	}
	return out
}

// CodeVersion reads the repo-root CODE_VERSION file once. Identical value in
// the identity block, OpenAPI info.version, the APM service.version, and every
// log line — so the version can never lie.
func CodeVersion() string {
	b, err := os.ReadFile("CODE_VERSION")
	if err != nil {
		return "0-unknown"
	}
	v := strings.TrimSpace(string(b))
	if v == "" {
		return "0-unknown"
	}
	return v
}

// RedisOptions builds the go-redis client options from the discrete vars.
// Returns nil when REDIS_HOST is empty (the rate-limiter degrades gracefully —
// /ready never gates on Redis, see architecture.md §8.1/§16-a).
func (s *Settings) RedisOptions() *redis.Options {
	if s.RedisHost == "" {
		return nil
	}
	return &redis.Options{
		Addr:     fmt.Sprintf("%s:%d", s.RedisHost, s.RedisPort),
		Password: s.RedisPassword,
		DB:       s.RedisDB,
	}
}

// JWTAlgorithmsList returns the pinned algorithm allowlist (default ["RS256"]).
// The verifier rejects any token whose alg is not in this set — this is the
// alg-confusion / alg:none defense (architecture.md §12/§16-c).
func (s *Settings) JWTAlgorithmsList() []string {
	out := splitCSV(s.JWTAlgorithms)
	if len(out) == 0 {
		return []string{"RS256"}
	}
	return out
}
