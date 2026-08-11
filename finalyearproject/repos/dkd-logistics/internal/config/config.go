// Package config loads logistics-svc configuration from DKD_* environment variables.
// Logistics owns its shipment aggregate + 6 logistics.shipment.* topics on the shared Postgres
// dkd_logistics; POD is recorded as a custody attestation, never a stock write (R1). (LOG-09)
package config

import (
	"fmt"
	"os"
	"strconv"
	"strings"
)

type Config struct {
	ServiceName  string
	OtlpEndpoint string
	Context      string
	Env         string
	HTTPPort    int
	MetricsPort int
	LogLevel    string

	KafkaBrokers  string
	ConsumerGroup string

	DBDSN      string
	DBHost     string
	DBPort     string
	DBName     string
	DBUser     string
	DBPassword string
	DBSSLMode  string

	JWTIssuer  string
	B2CURL     string
	CustodyURL string
	RabbitURL  string

	// AttestationPrivKey is the base64-std Ed25519 PRIVATE key (32-byte seed or 64-byte full key)
	// with which logistics signs the POD-ATTEST message for a custody attestation move (C3-F2e).
	// ENV ONLY — never printed or committed. Empty => POD posts no attestationSignature (custody
	// then falls back to requiring the human dual-signature; the C3-F2e POD path is disabled).
	AttestationPrivKey string
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
		ServiceName:  getenv("DKD_SERVICE_NAME", "logistics-svc"),
		OtlpEndpoint: getenv("DKD_OTLP_ENDPOINT", ""),
		Context:     getenv("DKD_CONTEXT", "logistics"),
		Env:         getenv("DKD_ENV", "local"),
		HTTPPort:    getenvInt("DKD_HTTP_PORT", 8080),
		MetricsPort: getenvInt("DKD_METRICS_PORT", 9090),
		LogLevel:    getenv("DKD_LOG_LEVEL", "info"),

		KafkaBrokers:  os.Getenv("DKD_KAFKA_BROKERS"),
		ConsumerGroup: getenv("DKD_CONSUMER_GROUP", "logistics-svc"),

		DBDSN:      os.Getenv("DKD_DB_DSN"),
		DBHost:     os.Getenv("DKD_DB_HOST"),
		DBPort:     getenv("DKD_DB_PORT", "5432"),
		DBName:     getenv("DKD_DB_NAME", "dkd_logistics"),
		DBUser:     os.Getenv("DKD_DB_USER"),
		DBPassword: os.Getenv("DKD_DB_PASSWORD"),
		DBSSLMode:  os.Getenv("DKD_DB_SSLMODE"),

		JWTIssuer:  os.Getenv("DKD_JWT_ISSUER"),
		B2CURL:     getenv("DKD_B2C_URL", ""),
		RabbitURL:  getenv("DKD_RABBITMQ_URL", ""),
		CustodyURL: getenv("DKD_CUSTODY_URL", ""),

		AttestationPrivKey: os.Getenv("DKD_LOGISTICS_ATTESTATION_PRIVKEY"),
	}
}

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
