defmodule Payment.Application do
  use Application
  require Logger
  alias Payment.Config

  @impl true
  def start(_type, _args) do
    if Config.service_name() == "" do
      IO.puts(:stderr, "FATAL: SERVICE_NAME required"); System.halt(1)
    end
    if Config.app_env() in ["stage", "prod"] do
      if Config.jwt_public_key_b64() == "", do: (IO.puts(:stderr, "FATAL: JWT_PUBLIC_KEY_B64 required"); System.halt(1))
      if Config.internal_service_token() == "", do: (IO.puts(:stderr, "FATAL: INTERNAL_SERVICE_TOKEN required"); System.halt(1))
    end
    :persistent_term.put(:payment_boot, System.monotonic_time(:second))
    setup_otel()
    Logger.info("starting #{Config.service_name()} code_version=#{Config.code_version()} port=#{Config.service_port()} env=#{Config.app_env()}")
    Payment.Bootstrap.ensure()

    children = [
      Payment.Obs.Metrics,
      Payment.Obs.Log,
      Payment.Repo,
      {Redix, Payment.Redis.opts()},
      {Phoenix.PubSub, name: Payment.PubSub},
      Payment.Outbox,
      Payment.PayoutWorker,
      PaymentWeb.Endpoint
    ]
    Supervisor.start_link(children, strategy: :one_for_one, name: Payment.Supervisor)
  end

  @impl true
  def config_change(changed, _new, removed) do
    PaymentWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp setup_otel do
    try do
      OpentelemetryPhoenix.setup(adapter: :bandit)
      OpentelemetryBandit.setup()
      # opentelemetry_ecto v1.2 emits only the legacy db.type="sql"; the Elastic OTLP intake maps
      # db.system → the dependency resource, so without it the dep shows generic "sql". Inject the
      # semantic-convention db.system=postgresql on every Ecto span → Dependencies shows "postgresql".
      # Force db.system=postgresql using the SAME atom-key/atom-value form the library uses
      # internally (:"db.system" => :postgresql) — a binary key gets dropped on export. The raw
      # Ecto.Adapters.SQL.query! path doesn't carry the adapter through telemetry, so the library's
      # own maybe_add_db_system never fires; this guarantees the Elastic OTLP intake maps the dep
      # span.destination.service.resource to "postgresql" instead of the generic "sql".
      OpentelemetryEcto.setup([:payment, :repo], additional_attributes: %{:"db.system" => :postgresql})
    rescue _ -> :ok
    catch _, _ -> :ok end
  end
end
