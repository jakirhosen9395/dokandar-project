defmodule Payment.Obs.Log do
  @moduledoc "3-sink ECS logger (stdout + Mongo + ES :9200) with OTel trace correlation."
  use GenServer
  require Record
  alias Payment.Config

  Record.defrecordp(:span_ctx, Record.extract(:span_ctx, from_lib: "opentelemetry_api/include/opentelemetry.hrl"))

  def start_link(_), do: GenServer.start_link(__MODULE__, %{mongo_q: [], es_q: [], mongo_up: false}, name: __MODULE__)

  def info(name, msg), do: emit("INFO", name, msg)
  def warn(name, msg), do: emit("WARNING", name, msg)
  def error(name, msg), do: emit("ERROR", name, msg)
  def mongo_healthy?, do: (try do GenServer.call(__MODULE__, :mongo_up, 500) rescue _ -> false catch _, _ -> false end)
  def access(ip, method, path, status, reason) do
    ts = Calendar.strftime(DateTime.utc_now(), "%d-%m-%Y %H:%M:%S")
    IO.puts("#{ts}    #{ip} - \"#{method} #{path} HTTP/1.1\" #{status} #{reason}")
  end

  defp trace_ids do
    try do
      case :otel_tracer.current_span_ctx() do
        ctx when Record.is_record(ctx, :span_ctx) ->
          tid = span_ctx(ctx, :trace_id); sid = span_ctx(ctx, :span_id)
          if tid in [0, :undefined] or is_nil(tid), do: {nil, nil}, else: {hex(tid, 32), hex(sid, 16)}
        _ -> {nil, nil}
      end
    rescue _ -> {nil, nil} catch _, _ -> {nil, nil} end
  end
  defp hex(int, w), do: :io_lib.format("~#{w}.16.0b", [int]) |> List.to_string()

  defp emit(level, name, msg) do
    {trace, span} = trace_ids()
    now = DateTime.utc_now()
    apm = if trace, do: %{
      "elasticapm_trace_id" => trace, "elasticapm_transaction_id" => trace, "elasticapm_span_id" => span,
      "elasticapm_service_name" => Config.apm_service_name(), "elasticapm_service_environment" => Config.app_env(),
      "elasticapm_labels" => %{"trace.id" => trace, "transaction.id" => trace, "span.id" => span, "service.name" => Config.apm_service_name(), "service.environment" => Config.app_env()}
    }, else: %{"elasticapm_service_name" => Config.apm_service_name(), "elasticapm_service_environment" => Config.app_env(), "elasticapm_labels" => %{"trace.id" => nil, "transaction.id" => nil, "span.id" => nil, "service.name" => Config.apm_service_name(), "service.environment" => Config.app_env()}}
    stdout = Map.merge(%{"asctime" => Calendar.strftime(now, "%Y-%m-%d %H:%M:%S,") <> (now.microsecond |> elem(0) |> div(1000) |> Integer.to_string() |> String.pad_leading(3, "0")), "name" => name, "levelname" => level, "message" => msg}, apm)
    IO.puts(Jason.encode!(stdout))
    doc = %{"@timestamp" => DateTime.to_iso8601(now), "log" => %{"level" => String.downcase(level), "logger" => name}, "message" => msg,
            "service" => %{"name" => Config.service_name(), "version" => Config.code_version(), "environment" => Config.app_env()},
            "labels" => %{"tenant" => Config.tenant(), "env_version" => Config.env_version()}}
    doc = if trace, do: Map.merge(doc, %{"trace" => %{"id" => trace}, "transaction" => %{"id" => trace}, "elasticapm_trace_id" => trace, "elasticapm_transaction_id" => trace, "elasticapm_service_name" => Config.apm_service_name(), "elasticapm_service_environment" => Config.app_env()}), else: doc
    (try do GenServer.cast(__MODULE__, {:ship, doc}) rescue _ -> :ok catch _, _ -> :ok end)
  end

  @impl true
  def init(state) do
    if Config.mongo_log_uri() != "", do: send(self(), :connect_mongo)
    schedule()
    {:ok, state}
  end
  @impl true
  def handle_call(:mongo_up, _from, s), do: {:reply, s.mongo_up, s}
  @impl true
  def handle_cast({:ship, doc}, s) do
    s = if Config.mongo_log_uri() != "" and length(s.mongo_q) < 5000, do: %{s | mongo_q: [doc | s.mongo_q]}, else: s
    s = if Config.es_url() != "" and length(s.es_q) < 5000, do: %{s | es_q: [doc | s.es_q]}, else: s
    {:noreply, s}
  end
  @impl true
  def handle_info(:connect_mongo, s) do
    case (try do Mongo.start_link(url: mongo_url()) rescue _ -> :error catch _, _ -> :error end) do
      {:ok, pid} -> {:noreply, %{s | mongo_up: true} |> Map.put(:mongo_pid, pid)}
      _ -> Process.send_after(self(), :connect_mongo, 5000); {:noreply, s}
    end
  end
  defp mongo_url do
    uri = Config.mongo_log_uri(); db = Config.mongo_log_db()
    cond do
      String.contains?(uri, "/?") -> String.replace(uri, "/?", "/#{db}?")
      String.ends_with?(uri, "/") -> uri <> db
      true -> uri <> "/" <> db
    end
  end
  def handle_info(:flush, s) do
    s = flush_mongo(s); s = flush_es(s); schedule(); {:noreply, s}
  end
  defp schedule, do: Process.send_after(self(), :flush, 2000)

  defp flush_mongo(%{mongo_pid: pid} = s) when is_pid(pid) do
    {batch, rest} = Enum.split(Enum.reverse(s.mongo_q), 500)
    if batch != [] do
      up = (try do Mongo.insert_many(pid, Config.service_name(), batch); true rescue _ -> false catch _, _ -> false end)
      %{s | mongo_q: Enum.reverse(rest), mongo_up: up}
    else s end
  end
  defp flush_mongo(s), do: s

  defp flush_es(s) do
    if Config.es_url() == "" do s else
      {batch, rest} = Enum.split(Enum.reverse(s.es_q), 500)
      if batch != [] do
        body = Enum.map_join(batch, "", fn d -> ~s({"create":{}}\n) <> Jason.encode!(d) <> "\n" end)
        url = String.trim_trailing(Config.es_url(), "/") <> "/logs-app-#{Config.service_name()}-default/_bulk"
        auth = if Config.es_user() != "", do: [auth: {:basic, "#{Config.es_user()}:#{Config.es_password()}"}], else: []
        (try do Req.post(url, [headers: [{"content-type", "application/x-ndjson"}], body: body, retry: false] ++ auth) rescue _ -> :ok catch _, _ -> :ok end)
        %{s | es_q: Enum.reverse(rest)}
      else s end
    end
  end
end
