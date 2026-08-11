Rails.application.routes.draw do
  # ── The five operational endpoints (no /api prefix) ──────────────────────────────
  get "/ready"        => "ops#ready"
  get "/health"       => "ops#health"
  get "/data"         => "ops#data"
  get "/metrics"      => "ops#metrics"
  get "/openapi.json" => "ops#openapi"
  get "/docs"         => "ops#docs"

  # ── Business API: /api/v1/shipping/* ─────────────────────────────────────────────
  scope "/api/v1/shipping" do
    post "/shipments"                     => "shipments#create"
    get  "/shipments/by-order/:sub_order_id" => "shipments#by_order"
    get  "/shipments/:id"                 => "shipments#show"
    get  "/quote"                         => "quotes#show"
    post "/webhooks/:courier"             => "webhooks#receive"
    get  "/admin/agents"                  => "agents#index"
    post "/admin/agents"                  => "agents#create"
  end

  # ── Bare-404 on every unmapped path (the BareNotFound middleware strips the body +
  #    Content-Type when this action marks the response). ──────────────────────────
  match "*unmatched", to: "application#bare_not_found", via: :all, constraints: { unmatched: /.*/ }
end
