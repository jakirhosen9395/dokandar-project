// Package config loads catalog-svc configuration from DKD_* environment variables.
// One bounded context, one database: dkd_catalog (R6).
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	ServiceName string
	OtlpEndpoint string
	Context     string
	Env         string
	HTTPPort    int
	MetricsPort int
	GrpcPort    int
	LogLevel    string

	KafkaBrokers  string
	ConsumerGroup string

	RabbitURL string // intra-context queues only (catalog.search-index); NOT the Published Language

	DBDSN      string
	DBHost     string
	DBPort     string
	DBName     string
	DBUser     string
	DBPassword string
	DBSSLMode  string

	SearchURL   string // OpenSearch (business search only; never observability ES)
	SearchIndex string // index name is NEEDS-INFO in canon -> configurable

	JWTIssuer string
}

func getenv(key, def string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return def
}

func getenvInt(key string, def int) int {
	if v := os.Getenv(key); v != "" {
		if n, err := strconv.Atoi(v); err == nil {
			return n
		}
	}
	return def
}

func Load() Config {
	return Config{
		ServiceName: getenv("DKD_SERVICE_NAME", "catalog-svc"),
		OtlpEndpoint: getenv("DKD_OTLP_ENDPOINT", ""),
		Context:     getenv("DKD_CONTEXT", "catalog"),
		Env:         getenv("DKD_ENV", "local"),
		HTTPPort:    getenvInt("DKD_HTTP_PORT", 8080),
		MetricsPort: getenvInt("DKD_METRICS_PORT", 9090),
		GrpcPort:    getenvInt("DKD_GRPC_PORT", 8081),
		LogLevel:    getenv("DKD_LOG_LEVEL", "info"),

		KafkaBrokers:  os.Getenv("DKD_KAFKA_BROKERS"),
		ConsumerGroup: getenv("DKD_CONSUMER_GROUP", "catalog-svc"),

		RabbitURL: os.Getenv("DKD_RABBITMQ_URL"),

		DBDSN:      os.Getenv("DKD_DB_DSN"),
		DBHost:     os.Getenv("DKD_DB_HOST"),
		DBPort:     getenv("DKD_DB_PORT", "5432"),
		DBName:     getenv("DKD_DB_NAME", "dkd_catalog"),
		DBUser:     os.Getenv("DKD_DB_USER"),
		DBPassword: os.Getenv("DKD_DB_PASSWORD"),
		DBSSLMode:  os.Getenv("DKD_DB_SSLMODE"),

		SearchURL:   os.Getenv("DKD_SEARCH_URL"),
		SearchIndex: getenv("DKD_SEARCH_INDEX", "catalog-products"),

		JWTIssuer: os.Getenv("DKD_JWT_ISSUER"),
	}
}

// DSN returns the explicit DKD_DB_DSN or composes one from the discrete parts.
// TLS is required by default; plaintext only when explicitly local.
func (c Config) DSN() string {
	if c.DBDSN != "" {
		return c.DBDSN
	}
	if c.DBHost == "" {
		return ""
	}
	ssl := c.DBSSLMode
	if ssl == "" {
		ssl = "require"
		if c.Env == "local" {
			ssl = "disable"
		}
	}
	return fmt.Sprintf("host=%s port=%s dbname=%s user=%s password=%s sslmode=%s",
		c.DBHost, c.DBPort, c.DBName, c.DBUser, c.DBPassword, ssl)
}

func (c Config) Brokers() []string {
	var out []string
	for _, b := range strings.Split(c.KafkaBrokers, ",") {
		if b = strings.TrimSpace(b); b != "" {
			out = append(out, b)
		}
	}
	return out
}

func (c Config) Validate() error {
	if len(c.Brokers()) == 0 {
		return fmt.Errorf("config: DKD_KAFKA_BROKERS is required")
	}
	if c.DSN() == "" {
		return fmt.Errorf("config: DKD_DB_DSN or DKD_DB_HOST is required")
	}
	if c.ConsumerGroup == "" {
		return fmt.Errorf("config: DKD_CONSUMER_GROUP is required")
	}
	return nil
}
