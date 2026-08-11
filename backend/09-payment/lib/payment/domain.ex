defmodule Payment.Domain do
  @moduledoc "Payment money-movement logic: intents, webhooks (HMAC + replay fence), refunds, payouts, commission."
  alias Payment.{Repo, Config}
  alias Payment.Obs.{Metrics, Log}

  defp query!(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params)
  defp query(sql, params \\ []), do: Ecto.Adapters.SQL.query(Repo, sql, params)

  defp fmt(nil), do: nil
  defp fmt(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
  defp fmt(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt) <> "Z"
  defp fmt(%Decimal{} = d), do: Decimal.to_integer(d)
  defp fmt(v) when is_binary(v) and byte_size(v) == 16, do: (case Ecto.UUID.load(v) do {:ok, s} -> s; _ -> v end)
  defp fmt(v), do: v
  defp to_maps(%Postgrex.Result{columns: cols, rows: rows}),
    do: Enum.map(rows, fn r -> cols |> Enum.zip(r) |> Map.new(fn {c, v} -> {c, fmt(v)} end) end)
  defp one(%Postgrex.Result{} = res), do: List.first(to_maps(res))

  @intent_cols "id::text,order_id::text,customer_id::text,shopkeeper_id::text,provider,amount_minor,currency,state,provider_intent_id,provider_redirect_url,created_at,settled_at"
  defp intent_dto(m), do: Map.take(m, ~w(id order_id customer_id shopkeeper_id provider amount_minor currency state provider_intent_id provider_redirect_url created_at settled_at))

  # ── intents ──────────────────────────────────────────────────────────────
  def create_intent(b) do
    order_id = b["order_id"]
    case existing_intent(order_id) do
      nil ->
        initial = if b["provider"] == "cod", do: "cod_pending", else: "pending"
        pintent = "stub_#{b["provider"]}_#{:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower)}"
        redirect = if b["provider"] in ~w(bkash nagad rocket sslcommerz stripe), do: "http://stub.example.com/checkout/#{pintent}", else: nil
        res = Repo.transaction(fn ->
          ins = query("""
            INSERT INTO payment_intents (order_id,customer_id,shopkeeper_id,provider,amount_minor,currency,state,provider_intent_id,provider_redirect_url,idempotency_key)
            VALUES ($1::text::uuid,$2::text::uuid,$3::text::uuid,$4,$5,$6,$7,$8,$9,$10) RETURNING #{@intent_cols}
          """, [order_id, b["customer_id"], b["shopkeeper_id"], b["provider"], b["amount_minor"], b["currency"] || "BDT", initial, pintent, redirect, order_id])
          case ins do
            {:ok, r} ->
              m = one(r)
              emit(m["provider"], Config.topic_intent_created, m["id"], %{event: "PaymentIntentCreated", intent_id: m["id"], order_id: m["order_id"], provider: m["provider"], amount_minor: m["amount_minor"], state: m["state"]})
              m
            {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> Repo.rollback(:conflict)
          end
        end)
        case res do
          {:ok, m} -> Metrics.inc("payment_intents_total", [service: Metrics.svc(), provider: b["provider"]]); Log.info("payment.api", "intent created id=#{m["id"]} order=#{m["order_id"]} provider=#{m["provider"]} state=#{m["state"]}"); intent_dto(m)
          {:error, :conflict} -> intent_dto(existing_intent(order_id))
        end
      m -> intent_dto(m)
    end
  end
  defp existing_intent(order_id), do: query!("SELECT #{@intent_cols} FROM payment_intents WHERE idempotency_key = $1::text", [order_id]) |> one()

  def get_intent(id) do
    case query("SELECT #{@intent_cols} FROM payment_intents WHERE id = $1::text::uuid", [id]) do
      {:ok, %{num_rows: 0}} -> :not_found
      {:ok, r} -> intent_dto(one(r))
      {:error, _} -> :not_found
    end
  end

  def list_intents_me(customer_id),
    do: query!("SELECT #{@intent_cols} FROM payment_intents WHERE customer_id = $1::text::uuid ORDER BY created_at DESC LIMIT 50", [customer_id]) |> to_maps() |> Enum.map(&intent_dto/1)

  # ── webhooks ─────────────────────────────────────────────────────────────
  def process_webhook(provider, raw_body, signature) do
    sig_ok = verify_signature(raw_body, signature)
    case Jason.decode(raw_body) do
      {:error, _} -> {:error, 400, "bad_request", "invalid JSON"}
      {:ok, payload} ->
        cond do
          not sig_ok ->
            Metrics.inc("payment_webhooks_total", [service: Metrics.svc(), provider: provider, result: "bad_signature"])
            {:error, 403, "signature_invalid", "HMAC signature verification failed"}
          true ->
            event_id = payload["event_id"] || payload["trxID"] || payload["paymentID"] || payload["id"] || ""
            if event_id == "" do
              {:error, 400, "bad_request", "missing event_id"}
            else
              dedup_key = "payment:webhook:dedup:#{provider}:#{event_id}"
              if Payment.Redis.exists?(dedup_key) do
                Metrics.inc("payment_webhooks_total", [service: Metrics.svc(), provider: provider, result: "duplicate_fast"])
                {:ok, %{ok: true, duplicate: true}}
              else
                settle_webhook(provider, event_id, raw_body, payload, dedup_key)
              end
            end
        end
    end
  end

  defp webhook_seen?(provider, event_id), do: query!("SELECT 1 FROM payment_webhooks WHERE provider=$1 AND event_id=$2", [provider, event_id]).num_rows > 0

  defp settle_webhook(provider, event_id, raw_body, payload, dedup_key) do
    order_id = payload["order_id"] || payload["merchantInvoiceNumber"]
    txn_id = payload["provider_txn_id"] || payload["trxID"] || event_id
    if webhook_seen?(provider, event_id) do
      Metrics.inc("payment_webhooks_total", [service: Metrics.svc(), provider: provider, result: "duplicate_pg"])
      {:ok, %{ok: true, duplicate: true}}
    else
      res = Repo.transaction(fn ->
        case query("INSERT INTO payment_webhooks (provider,event_id,raw_body,signature_ok,processed_at) VALUES ($1,$2,$3,true,now())", [provider, event_id, raw_body]) do
          {:error, %Postgrex.Error{postgres: %{code: :unique_violation}}} -> Repo.rollback(:duplicate)
          {:ok, _} ->
            sel = query!("SELECT id::text,state,shopkeeper_id::text,amount_minor FROM payment_intents WHERE provider=$1 AND (provider_intent_id=$2 OR order_id::text=$3) FOR UPDATE", [provider, event_id, order_id || ""])
            case one(sel) do
              nil -> %{ok: true, ignored: "no_matching_intent"}
              %{"state" => st} when st in ~w(settled refunded cancelled failed) -> %{ok: true, already_terminal: st}
              intent ->
                status = (payload["status"] || payload["state"] || "completed") |> to_string() |> String.downcase()
                if status in ~w(failed cancelled declined error) do
                  query!("UPDATE payment_intents SET state='failed' WHERE id=$1::text::uuid", [intent["id"]])
                  emit(provider, Config.topic_failed, intent["id"], %{event: "PaymentFailed", intent_id: intent["id"], provider: provider, reason: status})
                  Metrics.inc("payment_failed_total", [service: Metrics.svc(), provider: provider])
                  %{ok: true, failed: true}
                else
                  commission = compute_commission(intent["amount_minor"], intent["shopkeeper_id"])
                  net = intent["amount_minor"] - commission
                  query!("INSERT INTO payments (intent_id,provider_txn_id,amount_minor,commission_minor,net_to_shopkeeper_minor) VALUES ($1::text::uuid,$2,$3,$4,$5) ON CONFLICT (intent_id) DO NOTHING", [intent["id"], txn_id, intent["amount_minor"], commission, net])
                  query!("UPDATE payment_intents SET state='settled', settled_at=now() WHERE id=$1::text::uuid", [intent["id"]])
                  emit(provider, Config.topic_settled, intent["id"], %{event: "PaymentSettled", intent_id: intent["id"], provider: provider, amount_minor: intent["amount_minor"], commission_minor: commission, net_to_shopkeeper_minor: net})
                  %{ok: true, settled: true}
                end
            end
        end
      end)
      body = case res do
        {:ok, b} -> b
        {:error, :duplicate} -> Metrics.inc("payment_webhooks_total", [service: Metrics.svc(), provider: provider, result: "duplicate_pg"]); %{ok: true, duplicate: true}
      end
      if body[:settled] do
        Payment.Redis.setex(dedup_key, 7 * 24 * 3600, "1")
        Metrics.inc("payment_webhooks_total", [service: Metrics.svc(), provider: provider, result: "settled"])
        Metrics.inc("payment_settled_total", [service: Metrics.svc(), provider: provider])
      end
      {:ok, body}
    end
  end

  defp verify_signature(_raw, sig) when sig in [nil, ""], do: false
  defp verify_signature(raw, sig) do
    mac = :crypto.mac(:hmac, :sha256, Config.webhook_secret(), raw)
    # accept hex (scaffold) OR base64 (00-support provider-callback simulator)
    Plug.Crypto.secure_compare(Base.encode16(mac, case: :lower), sig) or Plug.Crypto.secure_compare(Base.encode64(mac), sig)
  end

  # ── refunds ──────────────────────────────────────────────────────────────
  def refund(b) do
    Repo.transaction(fn ->
      pay = query!("SELECT id::text,intent_id::text,amount_minor,commission_minor FROM payments WHERE intent_id=$1::text::uuid FOR UPDATE", [b["intent_id"]]) |> one()
      if pay == nil do
        Repo.rollback({:not_found, "no settled payment for this intent"})
      else
        reversed = if pay["amount_minor"] > 0, do: div(pay["commission_minor"] * b["refunded_amount_minor"], pay["amount_minor"]), else: 0
        query!("INSERT INTO commission_reversals (payment_id,refunded_amount_minor,reversed_commission_minor,return_id) VALUES ($1::text::uuid,$2,$3,$4)", [pay["id"], b["refunded_amount_minor"], reversed, b["return_id"]])
        query!("UPDATE payment_intents SET state='refunded' WHERE id=$1::text::uuid", [b["intent_id"]])
        emit(nil, Config.topic_refund_processed, b["intent_id"], %{event: "RefundProcessed", intent_id: b["intent_id"], refunded_amount_minor: b["refunded_amount_minor"], reversed_commission_minor: reversed})
        Metrics.inc("payment_refunds_total", [service: Metrics.svc()])
        %{ok: true, refunded_amount_minor: b["refunded_amount_minor"], reversed_commission_minor: reversed}
      end
    end)
  end

  # ── payouts (enqueue to RabbitMQ; worker confirms) ────────────────────────
  def create_payout(b) do
    Repo.transaction(fn ->
      rows = query!("SELECT p.id::text AS pid, p.net_to_shopkeeper_minor AS net, p.intent_id::text AS iid FROM payments p JOIN payment_intents i ON i.id=p.intent_id WHERE i.shopkeeper_id=$1::text::uuid AND p.paid_out=false FOR UPDATE", [b["shopkeeper_id"]]) |> to_maps()
      if rows == [] do
        Repo.rollback({:bad, "no_pending_amount", "no unpaid payments for this shopkeeper"})
      else
        total = Enum.reduce(rows, 0, fn r, a -> a + r["net"] end)
        intent_ids = rows |> Enum.map(& &1["iid"]) |> Enum.join(",")
        pay_ids = Enum.map(rows, & &1["pid"])
        po = query!("INSERT INTO payouts (shopkeeper_id,amount_minor,payment_intent_ids,method,destination,state) VALUES ($1::text::uuid,$2,$3,$4,$5,'enqueued') RETURNING id::text", [b["shopkeeper_id"], total, intent_ids, b["method"] || "bank_transfer", b["destination"]]) |> one()
        Enum.each(pay_ids, fn pid -> query!("UPDATE payments SET paid_out=true WHERE id=$1::text::uuid", [pid]) end)
        Payment.PayoutWorker.enqueue(%{payout_id: po["id"], shopkeeper_id: b["shopkeeper_id"], amount_minor: total})
        Metrics.inc("payment_payouts_total", [service: Metrics.svc(), state: "enqueued"])
        %{ok: true, payout_id: po["id"], amount_minor: total, intent_count: length(rows)}
      end
    end)
  end

  def list_payouts(nil), do: query!("SELECT id::text,shopkeeper_id::text,tier,amount_minor,payment_intent_ids,method,destination,state,attempts,provider_txn_id,created_at FROM payouts ORDER BY created_at DESC LIMIT 100", []) |> to_maps()
  def list_payouts(sk), do: query!("SELECT id::text,shopkeeper_id::text,tier,amount_minor,payment_intent_ids,method,destination,state,attempts,provider_txn_id,created_at FROM payouts WHERE shopkeeper_id=$1::text::uuid ORDER BY created_at DESC LIMIT 100", [sk]) |> to_maps()

  def cod_ledger(sk), do: query!("SELECT id,shopkeeper_id::text,order_id::text,commission_owed_minor,settled_via_payout_id::text,created_at FROM cod_ledger WHERE shopkeeper_id=$1::text::uuid AND settled_via_payout_id IS NULL ORDER BY created_at DESC LIMIT 200", [sk]) |> to_maps()

  # ── commission ───────────────────────────────────────────────────────────
  def list_commission_rates, do: query!("SELECT id::text,scope,scope_id::text,percent_basis_points,flat_minor,valid_from,valid_until,created_by::text,created_at FROM commission_rates ORDER BY valid_from DESC", []) |> to_maps()
  def create_commission_rate(b, sub),
    do: query!("INSERT INTO commission_rates (scope,scope_id,percent_basis_points,flat_minor,created_by) VALUES ($1,$2::text::uuid,$3,$4,$5::text::uuid) RETURNING id::text,scope,scope_id::text,percent_basis_points,flat_minor,valid_from,valid_until,created_by::text,created_at", [b["scope"], b["scope_id"], b["percent_basis_points"], b["flat_minor"] || 0, sub]) |> one()

  def compute_commission(amount, shopkeeper_id) do
    rate =
      (if shopkeeper_id, do: lookup_rate("shopkeeper", shopkeeper_id), else: nil) ||
        lookup_rate("platform_default", nil) ||
        %{"percent_basis_points" => Config.commission_default_bps(), "flat_minor" => 0}
    min(amount, div(amount * rate["percent_basis_points"], 10000) + rate["flat_minor"])
  end
  defp lookup_rate(scope, nil),
    do: query!("SELECT percent_basis_points,flat_minor FROM commission_rates WHERE scope=$1 AND valid_from<=now() AND (valid_until IS NULL OR valid_until>now()) ORDER BY valid_from DESC LIMIT 1", [scope]) |> one()
  defp lookup_rate(scope, id),
    do: query!("SELECT percent_basis_points,flat_minor FROM commission_rates WHERE scope=$1 AND scope_id=$2::text::uuid AND valid_from<=now() AND (valid_until IS NULL OR valid_until>now()) ORDER BY valid_from DESC LIMIT 1", [scope, id]) |> one()

  # ── outbox ───────────────────────────────────────────────────────────────
  defp emit(_provider, topic, key, payload),
    do: query!("INSERT INTO outbox (topic,key,payload) VALUES ($1,$2,$3::jsonb)", [topic, key, Jason.encode!(payload)])

  def outbox_pending do
    case query("SELECT count(*) FROM outbox WHERE sent_at IS NULL") do
      {:ok, %{rows: [[n]]}} -> n
      _ -> 0
    end
  end
end
