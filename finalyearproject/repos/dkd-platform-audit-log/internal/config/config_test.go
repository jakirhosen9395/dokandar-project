package config

import (
	"os"
	"testing"
)

func clearEnv(keys ...string) {
	for _, k := range keys {
		os.Unsetenv(k)
	}
}

func TestLoadDefaults(t *testing.T) {
	clearEnv("DKD_HTTP_PORT", "DKD_METRICS_PORT", "DKD_DB_DSN", "DKD_DB_HOST",
		"DKD_KAFKA_BROKERS", "DKD_CONSUMER_GROUP", "DKD_SERVICE_NAME")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	if c.ServiceName != "audit-log-svc" {
		t.Fatalf("service name=%s", c.ServiceName)
	}
	if c.ConsumerGroup != "audit-log-svc" {
		t.Fatalf("group=%s", c.ConsumerGroup)
	}
	if c.HTTPPort != 8080 || c.MetricsPort != 9090 {
		t.Fatalf("ports=%d/%d", c.HTTPPort, c.MetricsPort)
	}
}

func TestValidateRequiresBrokersAndDSN(t *testing.T) {
	c := &Config{ServiceName: "s", Context: "platform", HTTPPort: 8080, ConsumerGroup: "g"}
	if err := c.Validate(); err == nil {
		t.Fatal("want error: no brokers")
	}
	c.KafkaBrokers = "localhost:9092"
	if err := c.Validate(); err == nil {
		t.Fatal("want error: no dsn")
	}
	c.DBDSN = "postgres://x"
	if err := c.Validate(); err != nil {
		t.Fatalf("want ok: %v", err)
	}
}

func TestBrokersSplit(t *testing.T) {
	c := &Config{KafkaBrokers: "a:9092, b:9092 ,"}
	got := c.Brokers()
	if len(got) != 2 || got[0] != "a:9092" || got[1] != "b:9092" {
		t.Fatalf("brokers=%v", got)
	}
}

func TestDBDSNFromParts(t *testing.T) {
	clearEnv("DKD_DB_DSN")
	os.Setenv("DKD_DB_HOST", "h")
	os.Setenv("DKD_DB_PORT", "5433")
	os.Setenv("DKD_DB_NAME", "dkd_platform")
	os.Setenv("DKD_DB_USER", "u")
	os.Setenv("DKD_DB_PASSWORD", "p")
	defer clearEnv("DKD_DB_HOST", "DKD_DB_PORT", "DKD_DB_NAME", "DKD_DB_USER", "DKD_DB_PASSWORD")
	c, err := Load()
	if err != nil {
		t.Fatal(err)
	}
	want := "postgres://u:p@h:5433/dkd_platform?sslmode=disable"
	if c.DBDSN != want {
		t.Fatalf("dsn=%s want %s", c.DBDSN, want)
	}
}

func TestExtraTopicList(t *testing.T) {
	c := &Config{ExtraTopics: "a.b.C.v1, x.y.Z.v1 ,"}
	got := c.ExtraTopicList()
	if len(got) != 2 || got[0] != "a.b.C.v1" || got[1] != "x.y.Z.v1" {
		t.Fatalf("extra topics=%v", got)
	}
	if n := len((&Config{}).ExtraTopicList()); n != 0 {
		t.Fatalf("empty extra topics must yield none, got %d", n)
	}
}
