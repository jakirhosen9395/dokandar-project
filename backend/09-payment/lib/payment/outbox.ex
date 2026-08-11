defmodule Payment.Outbox do
  # Transactional outbox → Kafka (brod). Publish-before-mark; adaptive idle backoff.
  use GenServer
  require OpenTelemetry.Tracer, as: Tracer
  alias Payment.{Repo, Config}
  alias Payment.Obs.{Metrics, Log}
  @client :payment_brod

  def start_link(_), do: GenServer.start_link(__MODULE__, %{up: false, idle: 0}, name: __MODULE__)
  @impl true
  def init(s) do
    if Config.kafka_bootstrap() != "", do: send(self(), :connect)
    {:ok, s}
  end
  @impl true
  def handle_info(:connect, s) do
    case (try do start_brod() rescue _ -> :error catch _, _ -> :error end) do
      :ok -> Log.info("payment.outbox", "kafka producer connected"); Process.send_after(self(), :tick, 1000); {:noreply, %{s | up: true}}
      {:error, {:already_started, _}} -> Process.send_after(self(), :tick, 1000); {:noreply, %{s | up: true}}
      _ -> Process.send_after(self(), :connect, 5000); {:noreply, s}
    end
  end
  def handle_info(:tick, s) do
    n = (try do tick() rescue _ -> 0 catch _, _ -> 0 end)
    idle = if n > 0, do: 0, else: min(s.idle + 1, 5)
    Process.send_after(self(), :tick, 1000 * (1 + idle))
    {:noreply, %{s | idle: idle}}
  end
  def handle_info(_, s), do: {:noreply, s}

  defp start_brod do
    [hp | _] = String.split(Config.kafka_bootstrap(), ",")
    [h, p] = String.split(hp, ":")
    :brod.start_client([{String.to_charlist(h), String.to_integer(p)}], @client, [auto_start_producers: true])
  end

  defp tick do
    {:ok, n} = Repo.transaction(fn ->
      res = Ecto.Adapters.SQL.query!(Repo, "SELECT id, topic, key, payload::text FROM outbox WHERE sent_at IS NULL ORDER BY id LIMIT 100 FOR UPDATE SKIP LOCKED", [])
      case res.rows do
        [] -> 0
        rows ->
          # brod is not OTel-auto-instrumented and the relay has no request transaction. Wrap the
          # batch in a parent span (→ an APM transaction for this background job) and each produce in
          # a PRODUCER child span carrying messaging.system="kafka" → the OTLP intake surfaces a
          # friendly "kafka" dependency + service-map edge (never a raw broker host:port).
          Tracer.with_span "Outbox publish", %{kind: :internal} do
            sent = Enum.reduce_while(rows, [], fn [id, topic, key, payload], acc ->
              r = Tracer.with_span "kafka send #{topic}", %{kind: :producer} do
                Tracer.set_attributes([{"messaging.system", "kafka"}, {"messaging.destination.name", topic}, {"messaging.operation", "publish"}])
                :brod.produce_sync(@client, topic, :hash, (key || ""), payload)
              end
              case r do
                :ok -> {:cont, [id | acc]}
                _ -> {:halt, acc}
              end
            end)
            if sent != [] do
              Ecto.Adapters.SQL.query!(Repo, "UPDATE outbox SET sent_at=now() WHERE id = ANY($1)", [sent])
              Metrics.inc("payment_outbox_published_total", [service: Metrics.svc()], length(sent))
              Log.info("payment.outbox", "published #{length(sent)} event(s)")
            end
            length(sent)
          end
      end
    end)
    n
  end
end
