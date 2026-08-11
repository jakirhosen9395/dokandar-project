import Config

port = String.to_integer(System.get_env("SERVICE_PORT") || "4000")
config :payment, PaymentWeb.Endpoint,
  http: [ip: {0, 0, 0, 0}, port: port],
  secret_key_base: System.get_env("SECRET_KEY_BASE") || String.duplicate("a", 64)

config :payment, Payment.Repo,
  hostname: System.get_env("POSTGRES_HOST"),
  port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
  username: System.get_env("POSTGRES_USER") || "postgres",
  password: System.get_env("POSTGRES_PASSWORD") || "",
  database: System.get_env("POSTGRES_DB") || "dokandar_payment_dev",
  pool_size: 10,
  timeout: 5_000

# OTLP → Elastic APM server
apm = System.get_env("APM_SERVER_URL")
apm_token = System.get_env("APM_SECRET_TOKEN") || ""
if apm && apm != "" do
  config :opentelemetry_exporter,
    otlp_protocol: :http_protobuf,
    otlp_endpoint: apm,
    otlp_headers: (if apm_token != "", do: [{"authorization", "Bearer " <> apm_token}], else: [])
  # service.name + deployment.environment — the Elastic OTLP intake maps the OTel resource attribute
  # deployment.environment → service.environment (without it Kibana shows the env as "Not defined").
  config :opentelemetry, :resource,
    service: %{name: System.get_env("APM_SERVICE_NAME") || "09-payment"},
    deployment: %{environment: System.get_env("APP_ENV") || "dev"}
else
  config :opentelemetry, traces_exporter: :none
end
