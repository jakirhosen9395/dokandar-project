package config

import (
	"fmt"
	"os"
	"strings"

	"github.com/kelseyhightower/envconfig"
	"github.com/redis/go-redis/v9"
)

// Settings holds the full runtime configuration, read from DISCRETE env vars
// (never a single DSN — the init-env.sh render produces discrete POSTGRES_*,
// REDIS_*, etc.). Postgres/Redis connection strings are CONSTRUCTED from these.
type Settings struct {
	AppEnv      string `envconfig:"APP_ENV" default:"dev"`
	ServiceName string `envconfig:"SERVICE_NAME" default:"10-wallet"`
	EnvVersion  string `envconfig:"ENV_VERSION" default:"v1.0.0"`
	Tenant      string `envconfig:"TENANT" default:"local"`
	// SERVICE_PORT is 8080 in-container (the run line maps -p 10010:8080 and
	// passes -e SERVICE_PORT=8080). Default to the idiomatic in-container port.
	ServicePort int    `envconfig:"SERVICE_PORT" default:"8080"`
	LogLevel    string `envconfig:"LOG_LEVEL" default:"info"`

	// gRPC east-west server (Wallet.GetBalance|DebitWallet|CreditWallet).
	GRPCPort    int  `envconfig:"GRPC_PORT" default:"8001"`
	GRPCEnabled bool `envconfig:"GRPC_ENABLED" default:"true"`

	PostgresHost     string `envconfig:"POSTGRES_HOST" required:"true"`
	PostgresPort     int    `envconfig:"POSTGRES_PORT" default:"5432"`
	PostgresUser     string `envconfig:"POSTGRES_USER" required:"true"`
	PostgresPassword string `envconfig:"POSTGRES_PASSWORD" required:"true"`
	PostgresDB       string `envconfig:"POSTGRES_DB" default:"dokandar_wallet_dev"`

	RedisHost     string `envconfig:"REDIS_HOST"`
	RedisPort     int    `envconfig:"REDIS_PORT" default:"6379"`
	RedisPassword string `envconfig:"REDIS_PASSWORD"`
	RedisDB       int    `envconfig:"REDIS_DB" default:"4"`

	KafkaBootstrap        string `envconfig:"KAFKA_BOOTSTRAP"`
	KafkaTopicCredited    string `envconfig:"KAFKA_TOPIC_CREDITED" default:"dokandar.wallet.credited"`
	KafkaTopicDebited     string `envconfig:"KAFKA_TOPIC_DEBITED" default:"dokandar.wallet.debited"`
	KafkaTopicCashback    string `envconfig:"KAFKA_TOPIC_CASHBACK" default:"dokandar.wallet.cashback_granted"`
	KafkaTopicOrderPlaced string `envconfig:"KAFKA_TOPIC_ORDER_PLACED" default:"dokandar.order.placed"`
	KafkaConsumerGroup    string `envconfig:"KAFKA_CONSUMER_GROUP" default:"wallet-cashback"`

	JWTPublicKeyB64      string `envconfig:"JWT_PUBLIC_KEY_B64"`
	JWTIssuer            string `envconfig:"JWT_ISSUER" default:"dokandar-auth"`
	InternalServiceToken string `envconfig:"INTERNAL_SERVICE_TOKEN"`

	// Observability sinks.
	MongoLogURI           string `envconfig:"MONGO_LOG_URI"`
	MongoLogDB            string `envconfig:"MONGO_LOG_DB" default:"mongo_db_dokandar_application_logs"`
	ElasticSearchURL      string `envconfig:"ELASTIC_SEARCH_URL"`
	ElasticSearchUsername string `envconfig:"ELASTIC_SEARCH_USERNAME"`
	ElasticSearchPassword string `envconfig:"ELASTIC_SEARCH_PASSWORD"`
	APMServerURL          string `envconfig:"APM_SERVER_URL"`
	APMSecretToken        string `envconfig:"APM_SECRET_TOKEN"`
	APMServiceName        string `envconfig:"APM_SERVICE_NAME" default:"10-wallet"`

	// WalletMaxMinor is the 50,000 BDT regulatory cap expressed in paisa
	// (5,000,000). Mirrors the DB CHECK on wallet_balances.balance_minor.
	WalletMaxMinor int64 `envconfig:"WALLET_MAX_MINOR" default:"5000000"`
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
	if (s.AppEnv == "stage" || s.AppEnv == "prod") && s.JWTPublicKeyB64 == "" {
		return nil, fmt.Errorf("JWT_PUBLIC_KEY_B64 empty in stage/prod")
	}
	if s.APMServiceName == "" {
		s.APMServiceName = s.ServiceName
	}
	return s, nil
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

// PostgresDSN builds the application DSN to the service's own database.
func (s *Settings) PostgresDSN() string {
	return fmt.Sprintf("postgresql://%s:%s@%s:%d/%s?sslmode=disable",
		s.PostgresUser, s.PostgresPassword, s.PostgresHost, s.PostgresPort, s.PostgresDB)
}

// PostgresAdminDSN builds a DSN to the admin `postgres` database — used by
// ensure_db to CREATE DATABASE if the service DB is missing.
func (s *Settings) PostgresAdminDSN() string {
	return fmt.Sprintf("postgresql://%s:%s@%s:%d/postgres?sslmode=disable",
		s.PostgresUser, s.PostgresPassword, s.PostgresHost, s.PostgresPort)
}

// RedisOptions builds the go-redis client options from the discrete vars.
// Returns nil when REDIS_HOST is empty (Redlock is degradable — the SERIALIZABLE
// tx + balance CHECK + version are the correctness backstop).
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
