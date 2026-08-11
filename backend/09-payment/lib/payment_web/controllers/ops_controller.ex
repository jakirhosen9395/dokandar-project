defmodule PaymentWeb.OpsController do
  use Phoenix.Controller, formats: [:json]
  import PaymentWeb.Helpers
  alias Payment.{Config, Domain, Repo}
  alias Payment.Obs.{Metrics, Log}

  def ready(conn, _) do
    {ok, ms, detail} = check_pg()
    json_resp(conn, (if ok, do: 200, else: 503), %{
      status: (if ok, do: "ready", else: "not_ready"), identity: identity(),
      dependencies: [%{name: "postgres", reachable: ok, latency_ms: ms, detail: detail}]})
  end

  def health(conn, _) do
    {pg_ok, pg_ms, pg_detail} = check_pg()
    redis_ok = Payment.Redis.ping()
    kafka_ok = tcp_ok(Config.kafka_bootstrap(), 9092)
    rabbit_ok = amqp_ok(Config.rabbitmq_url())
    mongo_ok = Log.mongo_healthy?()
    apm_ok = Config.apm_server_url() != ""
    healthy = pg_ok
    json_resp(conn, (if healthy, do: 200, else: 503), %{
      status: (if healthy, do: "healthy", else: "unhealthy"), identity: identity(),
      checks: %{
        postgres: %{ok: pg_ok, latency_ms: pg_ms, detail: pg_detail},
        redis: %{ok: redis_ok, detail: (if redis_ok, do: "ok", else: "not-connected")},
        kafka: %{ok: kafka_ok, detail: (if kafka_ok, do: "metadata-ok", else: "unreachable")},
        rabbitmq: %{ok: rabbit_ok, detail: (if rabbit_ok, do: "tcp-ok", else: "unreachable")},
        mongo_logs: %{ok: mongo_ok, detail: (if mongo_ok, do: "ping-ok", else: "unreachable")},
        apm: %{ok: apm_ok, detail: (if apm_ok, do: "configured", else: "disabled")}},
      observability: %{apm_service_name: Config.apm_service_name(),
        logs_sink_mongo: (if Config.mongo_log_uri() == "", do: nil, else: "#{Config.mongo_log_db()}.#{Config.service_name()}"),
        logs_sink_es: (if Config.es_url() == "", do: nil, else: "#{Config.es_url()}/logs-app-#{Config.service_name()}-*")}})
  end

  def data(conn, _) do
    paths = ["data/#{Config.tenant()}/result.json", "/app/data/#{Config.tenant()}/result.json"]
    case Enum.find_value(paths, fn p -> (case File.read(p) do {:ok, c} -> c; _ -> nil end) end) do
      nil -> json_resp(conn, 404, %{error: %{code: "no_snapshot", message: "data/#{Config.tenant()}/result.json not present"}})
      content ->
        case Jason.decode(content) do
          {:ok, m} when is_map(m) -> json_resp(conn, 200, Map.merge(identity(), m))
          {:ok, _} -> json_resp(conn, 500, %{error: %{code: "snapshot_not_object", message: "snapshot root must be an object"}})
          {:error, _} -> json_resp(conn, 500, %{error: %{code: "snapshot_parse_failed", message: "invalid JSON"}})
        end
    end
  end

  def metrics(conn, _) do
    (try do Metrics.set("payment_outbox_pending", [service: Metrics.svc()], Domain.outbox_pending()) rescue _ -> :ok end)
    conn |> put_resp_content_type("text/plain; version=0.0.4; charset=utf-8") |> send_resp(200, Metrics.render())
  end

  def not_found(conn, _), do: conn |> delete_resp_header("content-type") |> send_resp(404, "")

  defp check_pg do
    t0 = System.monotonic_time(:microsecond)
    case (try do Ecto.Adapters.SQL.query(Repo, "SELECT 1", []) rescue e -> {:error, e} catch _, e -> {:error, e} end) do
      {:ok, _} -> {true, ms(t0), "ok"}
      {:error, e} -> {false, ms(t0), "err:#{inspect(if is_map(e) and Map.has_key?(e, :__struct__), do: e.__struct__, else: e)}"}
    end
  end
  defp ms(t0), do: Float.round((System.monotonic_time(:microsecond) - t0) / 1000, 2)
  defp tcp_ok(hostport, defport) do
    [h | rest] = String.split(hostport || "", ":")
    p = (case rest do [x | _] -> String.to_integer(x); _ -> defport end)
    case :gen_tcp.connect(String.to_charlist(h), p, [:binary], 2000) do
      {:ok, s} -> :gen_tcp.close(s); true; _ -> false
    end
  rescue _ -> false catch _, _ -> false end
  defp amqp_ok(url) do
    case URI.parse(url || "") do
      %URI{host: h, port: p} when is_binary(h) -> tcp_ok("#{h}:#{p || 5672}", 5672)
      _ -> false
    end
  end
end
