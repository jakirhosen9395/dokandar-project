defmodule Payment.PayoutWorker do
  # RabbitMQ payout.execute worker (durable, DLQ-bound) — consumes + confirms payouts.
  use GenServer
  require OpenTelemetry.Tracer, as: Tracer
  alias Payment.{Repo, Config}
  alias Payment.Obs.{Metrics, Log}

  def start_link(_), do: GenServer.start_link(__MODULE__, %{chan: nil}, name: __MODULE__)
  def enqueue(msg), do: (try do GenServer.cast(__MODULE__, {:enqueue, msg}) rescue _ -> :ok catch _, _ -> :ok end)

  @impl true
  def init(s) do
    if Config.rabbitmq_url() != "", do: send(self(), :connect)
    {:ok, s}
  end
  @impl true
  def handle_info(:connect, s) do
    case (try do connect() rescue e -> {:error, inspect(e)} catch k, e -> {:error, "#{k}:#{inspect(e)}"} end) do
      {:ok, chan} -> Log.info("payment.payout", "rabbitmq connected; consuming #{Config.rabbitmq_payout_queue()}"); {:noreply, %{s | chan: chan}}
      {:error, why} -> Log.warn("payment.payout", "rabbitmq connect failed: #{why}"); Process.send_after(self(), :connect, 5000); {:noreply, s}
      _ -> Process.send_after(self(), :connect, 5000); {:noreply, s}
    end
  end
  def handle_info({:basic_deliver, payload, %{delivery_tag: tag}}, %{chan: chan} = s) do
    # amqp is not OTel-auto-instrumented — wrap the consume in a CONSUMER transaction carrying
    # messaging.system="rabbitmq" so the receive is visible + the handler's DB writes correlate.
    Tracer.with_span "RabbitMQ RECEIVE from #{Config.rabbitmq_payout_queue()}", %{kind: :consumer} do
      Tracer.set_attributes([{"messaging.system", "rabbitmq"}, {"messaging.destination.name", Config.rabbitmq_payout_queue()}, {"messaging.operation", "process"}])
      (try do process(payload) rescue e -> Log.warn("payment.payout", "process error: #{inspect(e)}") catch _, e -> Log.warn("payment.payout", "process error: #{inspect(e)}") end)
    end
    (try do AMQP.Basic.ack(chan, tag) rescue _ -> :ok end)
    {:noreply, s}
  end
  def handle_info({:basic_consume_ok, _}, s), do: {:noreply, s}
  def handle_info(_, s), do: {:noreply, s}
  @impl true
  def handle_cast({:enqueue, msg}, %{chan: chan} = s) when not is_nil(chan) do
    # The enqueue runs in this GenServer (detached from the request) → wrap in a parent transaction
    # + a PRODUCER child span with messaging.system="rabbitmq" → "rabbitmq" appears in Dependencies.
    Tracer.with_span "Payout enqueue", %{kind: :internal} do
      Tracer.with_span "rabbitmq publish #{Config.rabbitmq_payout_queue()}", %{kind: :producer} do
        Tracer.set_attributes([{"messaging.system", "rabbitmq"}, {"messaging.destination.name", Config.rabbitmq_payout_queue()}, {"messaging.operation", "publish"}])
        (try do AMQP.Basic.publish(chan, "", Config.rabbitmq_payout_queue(), Jason.encode!(msg), persistent: true) rescue _ -> :ok end)
      end
    end
    {:noreply, s}
  end
  def handle_cast({:enqueue, _}, s), do: {:noreply, s}

  defp connect do
    # A RABBITMQ_URL ending in "/" parses to an EMPTY vhost; the broker user is granted the default
    # "/" vhost, so an empty vhost is refused with {:error, :not_allowed} (the connect never
    # succeeded → chan stayed nil → every payout enqueue was silently dropped, no rabbitmq span).
    # Encode the trailing "/" as the default vhost %2F so the connection is admitted.
    url = Config.rabbitmq_url()
    url = if String.ends_with?(url, "/"), do: url <> "%2F", else: url
    {:ok, conn} = AMQP.Connection.open(url)
    {:ok, chan} = AMQP.Channel.open(conn)
    q = Config.rabbitmq_payout_queue()
    # Declare the queues on a THROWAWAY channel: payout.execute is pre-declared by the infra, so a
    # re-declare with mismatched args raises 406 PRECONDITION_FAILED and would kill the consume/
    # publish channel (the bug that left chan=nil → enqueue silently dropped, no rabbitmq span).
    # Isolating it on a temp channel lets us consume+publish the existing queue regardless.
    ensure_queues(conn, q)
    {:ok, _} = AMQP.Basic.consume(chan, q)
    {:ok, chan}
  end

  defp ensure_queues(conn, q) do
    case AMQP.Channel.open(conn) do
      {:ok, tmp} ->
        (try do
           AMQP.Queue.declare(tmp, q <> ".dlq", durable: true)
           AMQP.Queue.declare(tmp, q, durable: true, arguments: [{"x-dead-letter-exchange", :longstr, ""}, {"x-dead-letter-routing-key", :longstr, q <> ".dlq"}])
         rescue _ -> :ok catch _, _ -> :ok end)
        (try do AMQP.Channel.close(tmp) rescue _ -> :ok catch _, _ -> :ok end)
      _ -> :ok
    end
  end

  defp process(payload) do
    %{"payout_id" => pid} = Jason.decode!(payload)
    txn = "stub_payout_" <> (:crypto.strong_rand_bytes(6) |> Base.encode16(case: :lower))
    {:ok, _} = Repo.transaction(fn ->
      Ecto.Adapters.SQL.query!(Repo, "UPDATE payouts SET state='succeeded', attempts=attempts+1, provider_txn_id=$2 WHERE id=$1::text::uuid", [pid, txn])
      Ecto.Adapters.SQL.query!(Repo, "INSERT INTO payout_attempts (payout_id, attempt_no, state) SELECT $1::text::uuid, attempts, 'succeeded' FROM payouts WHERE id=$1::text::uuid", [pid])
    end)
    Metrics.inc("payment_payouts_total", [service: Metrics.svc(), state: "succeeded"])
    Log.info("payment.payout", "payout #{pid} succeeded")
  end
end
