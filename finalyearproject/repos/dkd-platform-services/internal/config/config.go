// Package config loads platform-services (ctx #13) configuration from DKD_* env vars.
// Both deployables (scheduler-svc, notification-svc) share this loader; DB = dkd_platform
// (context #13's datastore, shared with audit-log-svc but with disjoint tables).
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

	JWTIssuer string

	// scheduler-svc
	TickMs          int
	NILTickMs       int
	EscrowAbandonMs int64
	NILGpids        string

	// notification-svc
	RabbitURL string
	B2CURL    string
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
		ServiceName:  getenv("DKD_SERVICE_NAME", "platform-svc"),
		OtlpEndpoint: getenv("DKD_OTLP_ENDPOINT", ""),
		Context:     getenv("DKD_CONTEXT", "platform"),
		Env:         getenv("DKD_ENV", "local"),
		HTTPPort:    getenvInt("DKD_HTTP_PORT", 8080),
		MetricsPort: getenvInt("DKD_METRICS_PORT", 9090),
		LogLevel:    getenv("DKD_LOG_LEVEL", "info"),

		KafkaBrokers:  os.Getenv("DKD_KAFKA_BROKERS"),
		ConsumerGroup: getenv("DKD_CONSUMER_GROUP", "platform-svc"),

		DBDSN:      os.Getenv("DKD_DB_DSN"),
		DBHost:     os.Getenv("DKD_DB_HOST"),
		DBPort:     getenv("DKD_DB_PORT", "5432"),
		DBName:     getenv("DKD_DB_NAME", "dkd_platform"),
		DBUser:     os.Getenv("DKD_DB_USER"),
		DBPassword: os.Getenv("DKD_DB_PASSWORD"),
		DBSSLMode:  os.Getenv("DKD_DB_SSLMODE"),

		JWTIssuer: os.Getenv("DKD_JWT_ISSUER"),

		TickMs:          getenvInt("DKD_SCHED_TICK_MS", 3000),
		NILTickMs:       getenvInt("DKD_NIL_TICK_MS", 60000), // canon: every 60s
		EscrowAbandonMs: int64(getenvInt("DKD_ESCROW_ABANDON_MS", 604800000)), // canon: 7d TTL
		NILGpids:        os.Getenv("DKD_NIL_GPIDS"), // GPID set source is NEEDS-INFO; env-driven

		RabbitURL: os.Getenv("DKD_RABBIT_URL"),
		B2CURL:    os.Getenv("DKD_B2C_URL"),
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
