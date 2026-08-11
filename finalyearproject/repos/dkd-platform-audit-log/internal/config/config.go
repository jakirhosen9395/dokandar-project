package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

// Config is 12-factor: everything from the environment. Secrets come from the platform secret
// manager in non-local environments (never committed).
type Config struct {
	ServiceName   string
	OtlpEndpoint  string
	Context       string
	Env           string
	HTTPPort      int
	MetricsPort   int
	LogLevel      string
	KafkaBrokers  string
	ConsumerGroup string
	ExtraTopics   string
	DBDSN         string
	OTELEndpoint  string
	JWTIssuer     string
}

func getenv(k, def string) string {
	if v := os.Getenv(k); v != "" {
		return v
	}
	return def
}

// dbDSN prefers an explicit DKD_DB_DSN, else composes one from the discrete DKD_DB_* variables
// (which is what the substrate's infra-endpoints.env supplies: host/port, no ready-made DSN).
func dbDSN() string {
	if v := os.Getenv("DKD_DB_DSN"); v != "" {
		return v
	}
	host := os.Getenv("DKD_DB_HOST")
	if host == "" {
		return ""
	}
	// TLS is required by default; only local dev may fall back to plaintext. Audit payloads (incl.
	// PII-flagged records) must not traverse the network in cleartext in staging/prod.
	sslDefault := "require"
	if getenv("DKD_ENV", "local") == "local" {
		sslDefault = "disable"
	}
	return fmt.Sprintf("postgres://%s:%s@%s:%s/%s?sslmode=%s",
		getenv("DKD_DB_USER", "dkd"), os.Getenv("DKD_DB_PASSWORD"),
		host, getenv("DKD_DB_PORT", "5432"),
		getenv("DKD_DB_NAME", "dkd_platform"), getenv("DKD_DB_SSLMODE", sslDefault))
}

func Load() (*Config, error) {
	port, err := strconv.Atoi(getenv("DKD_HTTP_PORT", "8080"))
	if err != nil {
		return nil, fmt.Errorf("DKD_HTTP_PORT: %w", err)
	}
	metricsPort, err := strconv.Atoi(getenv("DKD_METRICS_PORT", "9090"))
	if err != nil {
		return nil, fmt.Errorf("DKD_METRICS_PORT: %w", err)
	}
	return &Config{
		ServiceName:   getenv("DKD_SERVICE_NAME", "audit-log-svc"),
		OtlpEndpoint:  getenv("DKD_OTLP_ENDPOINT", ""),
		Context:       getenv("DKD_CONTEXT", "platform"),
		Env:           getenv("DKD_ENV", "local"),
		HTTPPort:      port,
		MetricsPort:   metricsPort,
		LogLevel:      getenv("DKD_LOG_LEVEL", "info"),
		KafkaBrokers:  getenv("DKD_KAFKA_BROKERS", "localhost:9092"),
		ConsumerGroup: getenv("DKD_CONSUMER_GROUP", "audit-log-svc"),
		ExtraTopics:   getenv("DKD_EXTRA_TOPICS", ""),
		DBDSN:         dbDSN(),
		OTELEndpoint:  getenv("DKD_OTEL_ENDPOINT", ""),
		JWTIssuer:     getenv("DKD_JWT_ISSUER", ""),
	}, nil
}

// Brokers splits the comma-separated broker list into seed addresses.
func (c *Config) Brokers() []string {
	var out []string
	for _, b := range strings.Split(c.KafkaBrokers, ",") {
		if b = strings.TrimSpace(b); b != "" {
			out = append(out, b)
		}
	}
	return out
}

// ExtraTopicList returns any operator-supplied extra topics (DKD_EXTRA_TOPICS), appended to the
// canonical AllTopics() set. Used for isolated verification/backfill topics WITHOUT polluting the
// spine or coupling to a business context. Empty in normal operation.
func (c *Config) ExtraTopicList() []string {
	var out []string
	for _, t := range strings.Split(c.ExtraTopics, ",") {
		if t = strings.TrimSpace(t); t != "" {
			out = append(out, t)
		}
	}
	return out
}

// Validate fails fast on missing required configuration. The audit sink cannot operate without
// both a broker to consume from and a database to append to.
func (c *Config) Validate() error {
	if c.ServiceName == "" || c.Context == "" {
		return fmt.Errorf("service name and context are required")
	}
	if c.HTTPPort <= 0 {
		return fmt.Errorf("invalid http port %d", c.HTTPPort)
	}
	if len(c.Brokers()) == 0 {
		return fmt.Errorf("DKD_KAFKA_BROKERS is required")
	}
	if c.DBDSN == "" {
		return fmt.Errorf("DKD_DB_DSN (or DKD_DB_HOST/...) is required")
	}
	if c.ConsumerGroup == "" {
		return fmt.Errorf("DKD_CONSUMER_GROUP is required")
	}
	return nil
}
