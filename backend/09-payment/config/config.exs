import Config
config :payment, ecto_repos: [Payment.Repo]
config :payment, PaymentWeb.Endpoint,
  adapter: Bandit.PhoenixAdapter,
  render_errors: [formats: [json: PaymentWeb.ErrorJSON], layout: false],
  pubsub_server: Payment.PubSub
config :phoenix, :json_library, Jason
config :logger, level: :info
# OTLP exporter → Elastic APM server (:8200); configured at runtime
config :opentelemetry, span_processor: :batch, traces_exporter: :otlp
import_config "#{config_env()}.exs"
