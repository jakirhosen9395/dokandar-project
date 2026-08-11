defmodule PaymentWeb.PaymentController do
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn, only: [get_req_header: 2]
  import PaymentWeb.Helpers
  alias Payment.{Domain, Config}
  alias PaymentWeb.Auth

  @providers ~w(bkash nagad rocket sslcommerz stripe bank_transfer wallet cod)

  # POST /intents — internal_token (13-order)
  def create_intent(conn, params) do
    if Config.internal_service_token() != "" and not Auth.internal_ok?(conn) do
      error_resp(conn, 401, "unauthorized", "x-internal-token missing or invalid")
    else
      cond do
        is_nil(params["order_id"]) -> error_resp(conn, 422, "invalid_request", "order_id required")
        is_nil(params["customer_id"]) -> error_resp(conn, 422, "invalid_request", "customer_id required")
        params["provider"] not in @providers -> error_resp(conn, 422, "invalid_request", "invalid provider")
        not (is_integer(params["amount_minor"]) and params["amount_minor"] >= 0) -> error_resp(conn, 422, "invalid_request", "amount_minor must be >= 0")
        true -> json_resp(conn, 201, Domain.create_intent(params))
      end
    end
  end

  def list_intents_me(conn, _), do: with_user(conn, fn c -> json_resp(conn, 200, Domain.list_intents_me(c["sub"])) end)

  def get_intent(conn, %{"id" => id}) do
    with_user(conn, fn claims ->
      case Domain.get_intent(id) do
        :not_found -> error_resp(conn, 404, "not_found", "intent not found")
        intent ->
          if intent["customer_id"] == claims["sub"] or Auth.admin?(claims),
            do: json_resp(conn, 200, intent),
            else: error_resp(conn, 403, "forbidden", "not the intent owner")
      end
    end)
  end

  def refund(conn, params) do
    with_admin(conn, fn _ ->
      cond do
        is_nil(params["intent_id"]) -> error_resp(conn, 422, "invalid_request", "intent_id required")
        not (is_integer(params["refunded_amount_minor"]) and params["refunded_amount_minor"] > 0) -> error_resp(conn, 422, "invalid_request", "refunded_amount_minor must be > 0")
        true ->
          case Domain.refund(params) do
            {:ok, result} -> json_resp(conn, 200, result)
            {:error, {:not_found, msg}} -> error_resp(conn, 404, "not_found", msg)
          end
      end
    end)
  end

  def create_payout(conn, params) do
    with_admin(conn, fn _ ->
      cond do
        is_nil(params["shopkeeper_id"]) -> error_resp(conn, 422, "invalid_request", "shopkeeper_id required")
        is_nil(params["destination"]) or params["destination"] == "" -> error_resp(conn, 422, "invalid_request", "destination required")
        true ->
          case Domain.create_payout(params) do
            {:ok, result} -> json_resp(conn, 200, result)
            {:error, {:bad, code, msg}} -> error_resp(conn, 400, code, msg)
          end
      end
    end)
  end

  def list_payouts(conn, params) do
    with_user(conn, fn claims ->
      sk = if Auth.admin?(claims), do: params["shopkeeper_id"], else: claims["sub"]
      json_resp(conn, 200, Domain.list_payouts(sk))
    end)
  end

  def cod_ledger(conn, params) do
    with_user(conn, fn claims ->
      sk = if Auth.admin?(claims), do: (params["shopkeeper_id"] || claims["sub"]), else: claims["sub"]
      json_resp(conn, 200, Domain.cod_ledger(sk))
    end)
  end

  def list_commission_rates(conn, _), do: with_admin(conn, fn _ -> json_resp(conn, 200, Domain.list_commission_rates()) end)

  def create_commission_rate(conn, params) do
    with_admin(conn, fn claims ->
      cond do
        params["scope"] not in ~w(platform_default category shopkeeper) -> error_resp(conn, 422, "invalid_request", "invalid scope")
        not (is_integer(params["percent_basis_points"]) and params["percent_basis_points"] >= 0 and params["percent_basis_points"] <= 10000) -> error_resp(conn, 422, "invalid_request", "percent_basis_points must be 0..10000")
        true -> json_resp(conn, 200, Domain.create_commission_rate(params, claims["sub"]))
      end
    end)
  end

  # POST /webhooks/{provider} — public, HMAC verified over the RAW body
  def webhook(conn, %{"provider" => provider}) do
    raw = (conn.assigns[:raw_body] || []) |> Enum.reverse() |> IO.iodata_to_binary()
    sig = get_req_header(conn, "x-signature") |> List.first()
    case Domain.process_webhook(provider, raw, sig) do
      {:ok, body} -> json_resp(conn, 200, body)
      {:error, status, code, msg} -> error_resp(conn, status, code, msg)
    end
  end

  defp with_user(conn, fun) do
    case Auth.verify_user(conn) do {:ok, c} -> fun.(c); {:error, s, code, m} -> error_resp(conn, s, code, m) end
  end
  defp with_admin(conn, fun) do
    case Auth.verify_admin(conn) do {:ok, c} -> fun.(c); {:error, s, code, m} -> error_resp(conn, s, code, m) end
  end
end
