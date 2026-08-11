// Package config loads provenance-svc configuration. Context #4 is a pure CQRS read model of
// custody on the Neo4j-class graph engine (R1: never writes custody truth).
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

	Neo4jURI      string
	Neo4jUser     string
	Neo4jPassword string

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
		ServiceName:  getenv("DKD_SERVICE_NAME", "provenance-svc"),
		OtlpEndpoint: getenv("DKD_OTLP_ENDPOINT", ""),
		Context:     getenv("DKD_CONTEXT", "provenance"),
		Env:         getenv("DKD_ENV", "local"),
		HTTPPort:    getenvInt("DKD_HTTP_PORT", 8080),
		MetricsPort: getenvInt("DKD_METRICS_PORT", 9090),
		LogLevel:    getenv("DKD_LOG_LEVEL", "info"),

		KafkaBrokers:  os.Getenv("DKD_KAFKA_BROKERS"),
		ConsumerGroup: getenv("DKD_CONSUMER_GROUP", "provenance-svc"),

		Neo4jURI:      getenv("DKD_NEO4J_URI", "bolt://localhost:7687"),
		Neo4jUser:     getenv("DKD_NEO4J_USER", "neo4j"),
		Neo4jPassword: os.Getenv("DKD_NEO4J_PASSWORD"),

		JWTIssuer: os.Getenv("DKD_JWT_ISSUER"),
	}
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
	if c.Neo4jURI == "" || c.Neo4jPassword == "" {
		return fmt.Errorf("config: DKD_NEO4J_URI and DKD_NEO4J_PASSWORD are required")
	}
	if c.ConsumerGroup == "" {
		return fmt.Errorf("config: DKD_CONSUMER_GROUP is required")
	}
	return nil
}
