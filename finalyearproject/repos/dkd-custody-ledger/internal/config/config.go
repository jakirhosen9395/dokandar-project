// Package config loads custody-ledger-svc configuration from DKD_* environment variables.
// Custody runs against its DEDICATED Postgres instance (R1 isolation): dkd_custody.
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
	Context     string
	Env         string
	HTTPPort    int
	GrpcPort    int
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

	// CatalogURL enables the GPID-must-be-PUBLISHED precondition (R7 conformance) via the
	// Catalog read surface; empty = precondition skipped with a warning (documented substitution
	// until the catalog gRPC OHS lands).
	CatalogURL      string
	IdentityGrpcURL string

	JWTIssuer string

	// TrustAnchorPubKey is the base64-std Ed25519 PUBLIC key of the signer-key trust anchor (CA)
	// used to authorize key->DID bindings on POST /v1/custody/signer-keys (C3-F2c; FR-PASS-070
	// root of trust; dev stand-in for the future national PKI, BR-014). The CA PRIVATE key is
	// NEVER held by this service. Empty = registration FAILS CLOSED (rejects all bindings).
	TrustAnchorPubKey string

	// AttestationAuthorityPubKey is the base64-std Ed25519 PUBLIC key of the trusted
	// ATTESTATION AUTHORITY (C3-F2e; FR-PASS-014 shipment-linked transfer / FR-PASS-070 server-side
	// authorization for automated low-tech flows). It authorizes SINGLE-signature, reference-linked
	// custody moves (e.g. a logistics POD) that are saga-internal, NOT human hand-offs — distinct
	// from the dual holder co-signature (C3-F2b(ii)), which remains mandatory for direct human
	// transfers. The authority PRIVATE key is NEVER held by this service (it lives in logistics).
	// Empty = attestation mode is UNAVAILABLE (a transfer bearing an attestationSignature is
	// rejected — fail closed, never fall open to the human path).
	AttestationAuthorityPubKey string
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
		ServiceName:  getenv("DKD_SERVICE_NAME", "custody-ledger-svc"),
		OtlpEndpoint: getenv("DKD_OTLP_ENDPOINT", ""),
		Context:     getenv("DKD_CONTEXT", "custody"),
		Env:         getenv("DKD_ENV", "local"),
		HTTPPort:    getenvInt("DKD_HTTP_PORT", 8080),
		GrpcPort:    getenvInt("DKD_GRPC_PORT", 8081),
		MetricsPort: getenvInt("DKD_METRICS_PORT", 9090),
		LogLevel:    getenv("DKD_LOG_LEVEL", "info"),

		KafkaBrokers:  os.Getenv("DKD_KAFKA_BROKERS"),
		ConsumerGroup: getenv("DKD_CONSUMER_GROUP", "custody-ledger-svc"),

		DBDSN:      os.Getenv("DKD_DB_DSN"),
		DBHost:     os.Getenv("DKD_DB_HOST"),
		DBPort:     getenv("DKD_DB_PORT", "5435"),
		DBName:     getenv("DKD_DB_NAME", "dkd_custody"),
		DBUser:     os.Getenv("DKD_DB_USER"),
		DBPassword: os.Getenv("DKD_DB_PASSWORD"),
		DBSSLMode:  os.Getenv("DKD_DB_SSLMODE"),

		CatalogURL:      os.Getenv("DKD_CATALOG_URL"),
		IdentityGrpcURL: os.Getenv("DKD_IDENTITY_GRPC_URL"),

		JWTIssuer: os.Getenv("DKD_JWT_ISSUER"),

		TrustAnchorPubKey: os.Getenv("DKD_CUSTODY_TRUST_ANCHOR_PUBKEY"),

		AttestationAuthorityPubKey: os.Getenv("DKD_CUSTODY_ATTESTATION_AUTHORITY_PUBKEY"),
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
	// C3-F9 / R7: fail-CLOSED — custody may only initialize PUBLISHED catalog products, so the
	// Catalog OHS URL is mandatory. Never silently skip the GPID-PUBLISHED precondition (was: warn
	// + proceed when DKD_CATALOG_URL was unset, letting genesis bypass R7).
	if c.CatalogURL == "" {
		return fmt.Errorf("config: DKD_CATALOG_URL is required (R7 GPID-PUBLISHED precondition; fail-closed)")
	}
	return nil
}
