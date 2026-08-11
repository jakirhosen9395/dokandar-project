// Package config exposes a single typed Settings struct loaded from the
// process environment via envconfig. APP_ENV chooses env/.env.<APP_ENV>
// at deploy time (read by docker --env-file or by an external loader);
// this package only consumes the resulting env vars.
package config

import (
	"fmt"
	"os"

	"github.com/kelseyhightower/envconfig"
)

type Settings struct {
	AppEnv       string `envconfig:"APP_ENV"          default:"dev"`
	ServiceName  string `envconfig:"SERVICE_NAME"     default:"profile"`
	EnvVersion   string `envconfig:"ENV_VERSION"      default:"v1.0.0"`
	Tenant       string `envconfig:"TENANT"           default:"local"`
	ServicePort  int    `envconfig:"SERVICE_PORT"     default:"8000"`
	GRPCPort     int    `envconfig:"GRPC_PORT"        default:"8001"`
	GRPCEnabled  bool   `envconfig:"GRPC_ENABLED"     default:"true"`

	PostgresDSN      string `envconfig:"POSTGRES_DSN"       required:"true"`
	PostgresAdminDSN string `envconfig:"POSTGRES_ADMIN_DSN" required:"true"`

	RedisURL            string `envconfig:"REDIS_URL"                 required:"true"`
	ProfileCacheTTLSecs int    `envconfig:"PROFILE_CACHE_TTL_SECONDS" default:"300"`

	KafkaBootstrap           string `envconfig:"KAFKA_BOOTSTRAP"             required:"true"`
	KafkaTopicUser           string `envconfig:"KAFKA_TOPIC_USER"            default:"dokandar.user.created"`
	KafkaTopicUserUpdated    string `envconfig:"KAFKA_TOPIC_USER_UPDATED"    default:"dokandar.user.updated"`
	KafkaTopicKycSubmitted   string `envconfig:"KAFKA_TOPIC_KYC_SUBMITTED"   default:"dokandar.kyc.submitted"`
	KafkaTopicKycApproved    string `envconfig:"KAFKA_TOPIC_KYC_APPROVED"    default:"dokandar.kyc.approved"`
	KafkaTopicKycRejected    string `envconfig:"KAFKA_TOPIC_KYC_REJECTED"    default:"dokandar.kyc.rejected"`
	KafkaTopicProfileChanged string `envconfig:"KAFKA_TOPIC_PROFILE_CHANGED" default:"dokandar.profile.changed"`
	KafkaTopicAddressChanged string `envconfig:"KAFKA_TOPIC_ADDRESS_CHANGED" default:"dokandar.address.changed"`
	KafkaConsumerGrp         string `envconfig:"KAFKA_CONSUMER_GROUP"        default:"profile"`

	MongoLogURI string `envconfig:"MONGO_LOG_URI" required:"true"`
	MongoLogDB  string `envconfig:"MONGO_LOG_DB"  default:"mongo_db_dokandar_application_logs"`

	APMServerURL   string `envconfig:"APM_SERVER_URL"   required:"true"`
	APMSecretToken string `envconfig:"APM_SECRET_TOKEN" default:""`
	APMServiceName string `envconfig:"APM_SERVICE_NAME" default:"profile"`

	ElasticSearchURL      string `envconfig:"ELASTIC_SEARCH_URL"      default:""`
	ElasticSearchUsername string `envconfig:"ELASTIC_SEARCH_USERNAME" default:""`
	ElasticSearchPassword string `envconfig:"ELASTIC_SEARCH_PASSWORD" default:""`

	JWTPublicKeyB64 string `envconfig:"JWT_PUBLIC_KEY_B64" required:"true"`
	JWTIssuer       string `envconfig:"JWT_ISSUER"         default:"dokandar-auth"`

	InternalServiceToken string `envconfig:"INTERNAL_SERVICE_TOKEN" default:""`

	// Media gRPC — used by POST /me/avatar to mint presigned upload URLs.
	// Reported on /health.checks.grpc_media as a diagnostic dep (NOT on
	// /ready — a flapping Media must not drop Profile out of the LB).
	// Empty when the Media service isn't deployed yet; the check then
	// emits {ok:false, detail:"not_configured"}.
	MediaGRPCAddr string `envconfig:"MEDIA_GRPC_ADDR" default:""`

	LogLevel string `envconfig:"LOG_LEVEL" default:"info"`
}

// Load reads the process env into a Settings.
func Load() (*Settings, error) {
	var s Settings
	if err := envconfig.Process("", &s); err != nil {
		return nil, fmt.Errorf("config: %w", err)
	}
	return &s, nil
}

// CodeVersion reads the CODE_VERSION file alongside the binary.
func CodeVersion() string {
	for _, p := range []string{"CODE_VERSION", "./CODE_VERSION", "/app/CODE_VERSION"} {
		if b, err := os.ReadFile(p); err == nil {
			return string(trimNewline(b))
		}
	}
	return "0-unknown"
}

func trimNewline(b []byte) []byte {
	for len(b) > 0 && (b[len(b)-1] == '\n' || b[len(b)-1] == '\r' || b[len(b)-1] == ' ') {
		b = b[:len(b)-1]
	}
	return b
}
