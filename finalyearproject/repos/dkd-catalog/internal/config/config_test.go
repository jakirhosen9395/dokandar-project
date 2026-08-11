package config

import (
	"strings"
	"testing"
)

func setEnv(t *testing.T, kv map[string]string) {
	t.Helper()
	for k, v := range kv {
		t.Setenv(k, v)
	}
}

func TestLoadDefaults(t *testing.T) {
	setEnv(t, map[string]string{"DKD_KAFKA_BROKERS": "b1:9092"})
	c := Load()
	if c.ServiceName != "catalog-svc" || c.Context != "catalog" || c.Env != "local" {
		t.Fatalf("defaults: %+v", c)
	}
	if c.HTTPPort != 8080 || c.MetricsPort != 9090 {
		t.Fatalf("port defaults: %d %d", c.HTTPPort, c.MetricsPort)
	}
	if c.DBName != "dkd_catalog" || c.SearchIndex != "catalog-products" {
		t.Fatalf("names: %s %s", c.DBName, c.SearchIndex)
	}
}

func TestPortParsing(t *testing.T) {
	setEnv(t, map[string]string{"DKD_HTTP_PORT": "8188", "DKD_METRICS_PORT": "not-a-number"})
	c := Load()
	if c.HTTPPort != 8188 {
		t.Fatalf("http port: %d", c.HTTPPort)
	}
	if c.MetricsPort != 9090 { // invalid -> default
		t.Fatalf("metrics port fallback: %d", c.MetricsPort)
	}
}

func TestDSNComposition(t *testing.T) {
	setEnv(t, map[string]string{
		"DKD_DB_HOST": "db.internal", "DKD_DB_USER": "u", "DKD_DB_PASSWORD": "p",
	})
	c := Load()
	dsn := c.DSN()
	for _, want := range []string{"host=db.internal", "dbname=dkd_catalog", "user=u", "sslmode=disable"} {
		if !strings.Contains(dsn, want) {
			t.Fatalf("dsn %q missing %q", dsn, want)
		}
	}
}

// TLS is required by default outside local (H4 rule inherited from the reference service).
func TestDSNSSLModeRequireOutsideLocal(t *testing.T) {
	setEnv(t, map[string]string{"DKD_DB_HOST": "h", "DKD_ENV": "staging"})
	if dsn := Load().DSN(); !strings.Contains(dsn, "sslmode=require") {
		t.Fatalf("non-local must default to sslmode=require: %s", dsn)
	}
}

func TestExplicitDSNWins(t *testing.T) {
	setEnv(t, map[string]string{"DKD_DB_DSN": "host=explicit dbname=x", "DKD_DB_HOST": "ignored"})
	if dsn := Load().DSN(); dsn != "host=explicit dbname=x" {
		t.Fatalf("explicit DSN must win: %s", dsn)
	}
}

func TestBrokersSplit(t *testing.T) {
	setEnv(t, map[string]string{"DKD_KAFKA_BROKERS": " a:9092 , b:9092 ,, "})
	b := Load().Brokers()
	if len(b) != 2 || b[0] != "a:9092" || b[1] != "b:9092" {
		t.Fatalf("brokers: %v", b)
	}
}

func TestValidate(t *testing.T) {
	setEnv(t, map[string]string{"DKD_KAFKA_BROKERS": "", "DKD_DB_HOST": ""})
	if err := Load().Validate(); err == nil {
		t.Fatal("missing brokers must fail validation")
	}
	setEnv(t, map[string]string{"DKD_KAFKA_BROKERS": "b:9092"})
	if err := Load().Validate(); err == nil {
		t.Fatal("missing DB must fail validation")
	}
	setEnv(t, map[string]string{"DKD_DB_HOST": "h"})
	if err := Load().Validate(); err != nil {
		t.Fatalf("valid config rejected: %v", err)
	}
}
