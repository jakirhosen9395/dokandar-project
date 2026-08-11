defmodule Payment.Redis do
  # Redis DB8 — webhook dedup + provider rate-limit windows. Degradable: never raises into the request.
  alias Payment.Config
  require OpenTelemetry.Tracer, as: Tracer
  # redix is not OTel-auto-instrumented — wrap request-path ops in a CLIENT span with the semconv
  # db.system="redis" so the APM OTLP intake surfaces a friendly "redis" dependency + service-map edge.
  def opts do
    [host: Config.redis_host(), port: Config.redis_port(), database: Config.redis_db(),
     password: (case Config.redis_password() do "" -> nil; p -> p end),
     name: :payment_redix, sync_connect: false, exit_on_disconnection: false]
  end
  def exists?(key) do
    Tracer.with_span "redis EXISTS", %{kind: :client} do
      Tracer.set_attributes([{"db.system", "redis"}, {"db.operation", "EXISTS"}])
      try do
        case Redix.command(:payment_redix, ["EXISTS", key]) do {:ok, 1} -> true; _ -> false end
      rescue _ -> false catch _, _ -> false end
    end
  end
  def setex(key, ttl, val) do
    Tracer.with_span "redis SET", %{kind: :client} do
      Tracer.set_attributes([{"db.system", "redis"}, {"db.operation", "SET"}])
      try do Redix.command(:payment_redix, ["SET", key, val, "EX", to_string(ttl)]) rescue _ -> :ok catch _, _ -> :ok end
    end
  end
  def ping do
    try do (case Redix.command(:payment_redix, ["PING"]) do {:ok, _} -> true; _ -> false end) rescue _ -> false catch _, _ -> false end
  end
end
