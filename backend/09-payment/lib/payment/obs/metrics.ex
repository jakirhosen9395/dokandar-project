defmodule Payment.Obs.Metrics do
  # ETS-backed Prometheus counters/gauges. Keys are {name, labels_kw}. Closed-set labels only.
  use GenServer
  @svc "09-payment"
  @table :payment_metrics

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)
  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, write_concurrency: true])
    {:ok, %{}}
  end

  def inc(name, labels \\ [], by \\ 1) do
    key = {name, Enum.sort(labels)}
    try do :ets.update_counter(@table, key, by, {key, 0}) rescue _ -> 0 end
  end
  def set(name, labels, value) do
    try do :ets.insert(@table, {{name, Enum.sort(labels)}, value}) rescue _ -> :ok end
  end

  @help %{
    "http_requests_total" => "counter", "payment_intents_total" => "counter",
    "payment_settled_total" => "counter", "payment_webhooks_total" => "counter",
    "payment_refunds_total" => "counter", "payment_payouts_total" => "counter",
    "payment_failed_total" => "counter", "payment_outbox_published_total" => "counter",
    "payment_outbox_pending" => "gauge"
  }

  def render do
    rows = (try do :ets.tab2list(@table) rescue _ -> [] end)
    grouped = Enum.group_by(rows, fn {{name, _}, _} -> name end)
    Enum.map_join(grouped, "", fn {name, entries} ->
      type = Map.get(@help, name, "counter")
      header = "# HELP #{name} #{name}\n# TYPE #{name} #{type}\n"
      body = Enum.map_join(entries, "", fn {{_, labels}, val} ->
        lbls = labels |> Enum.map(fn {k, v} -> "#{k}=\"#{v}\"" end) |> Enum.join(",")
        if lbls == "", do: "#{name} #{val}\n", else: "#{name}{#{lbls}} #{val}\n"
      end)
      header <> body
    end)
  end

  def svc, do: @svc
end
