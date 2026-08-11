defmodule PaymentWeb.Router do
  use Phoenix.Router
  import Plug.Conn

  pipeline :api do
    plug :accepts, ["json"]
  end

  scope "/", PaymentWeb do
    pipe_through :api
    get "/ready", OpsController, :ready
    get "/health", OpsController, :health
    get "/data", OpsController, :data
    get "/metrics", OpsController, :metrics
    get "/openapi.json", OpenApiController, :spec
    get "/docs", OpenApiController, :docs

    scope "/api/v1/payment" do
      post "/intents", PaymentController, :create_intent
      get "/intents/me", PaymentController, :list_intents_me
      get "/intents/:id", PaymentController, :get_intent
      post "/refunds", PaymentController, :refund
      post "/payouts", PaymentController, :create_payout
      get "/payouts", PaymentController, :list_payouts
      get "/cod-ledger", PaymentController, :cod_ledger
      get "/commission-rates", PaymentController, :list_commission_rates
      post "/commission-rates", PaymentController, :create_commission_rate
      post "/webhooks/:provider", PaymentController, :webhook
    end

    match :*, "/*path", OpsController, :not_found
  end
end
