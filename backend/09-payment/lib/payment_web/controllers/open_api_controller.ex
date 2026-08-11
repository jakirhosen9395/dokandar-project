defmodule PaymentWeb.OpenApiController do
  use Phoenix.Controller, formats: [:json]
  import Plug.Conn
  import PaymentWeb.Helpers, only: [identity: 0]
  alias Payment.Config

  def spec(conn, _), do: conn |> put_resp_content_type("application/json") |> send_resp(200, Jason.encode!(build()))
  def docs(conn, _), do: conn |> put_resp_content_type("text/html") |> send_resp(200, html())

  defp s(t), do: %{type: t}
  defp ref(n), do: %{"$ref" => "#/components/schemas/#{n}"}

  # --- per-operation builder ------------------------------------------------
  # tag, summary, operationId, security, requestBody {ref, example}, params, responses
  defp op(opts) do
    m = %{
      tags: [opts[:tag]],
      summary: opts[:summary],
      operationId: opts[:id],
      responses: opts[:responses]
    }
    m = if opts[:desc], do: Map.put(m, :description, opts[:desc]), else: m
    m = if opts[:sec], do: Map.put(m, :security, opts[:sec]), else: m
    m = if opts[:params], do: Map.put(m, :parameters, opts[:params]), else: m
    if opts[:body] do
      rb = %{required: true, content: %{"application/json" => %{schema: ref(opts[:body])}}}
      rb = if opts[:body_ex], do: put_in(rb, [:content, "application/json", :example], opts[:body_ex]), else: rb
      Map.put(m, :requestBody, rb)
    else
      m
    end
  end

  # success response with optional schema $ref + example
  defp ok(code, desc, schema \\ nil, example \\ nil) do
    body = %{description: desc}
    body =
      if schema do
        c = %{schema: ref(schema)}
        c = if example, do: Map.put(c, :example, example), else: c
        Map.put(body, :content, %{"application/json" => c})
      else
        body
      end
    %{to_string(code) => body}
  end

  # error response → ErrorEnvelope $ref, with a worked example
  defp err(code, code_str, message) do
    %{to_string(code) => %{
      description: code_str,
      content: %{"application/json" => %{
        schema: ref("ErrorEnvelope"),
        example: %{error: %{code: code_str, message: message, request_id: "req-7f3a…", details: %{}}}}}}}
  end

  defp path_p(name, ex, desc), do: %{name: name, in: "path", required: true, schema: %{type: "string"}, description: desc, example: ex}
  defp query_p(name, type, req, ex, desc), do: %{name: name, in: "query", required: req, schema: %{type: type}, description: desc, example: ex}

  # --- request-body examples (prefill the Try-it-out box) -------------------
  defp ex_intent, do: %{order_id: "ord_01HZ…", customer_id: "11111111-1111-4111-8111-111111111111", shopkeeper_id: "22222222-2222-4222-8222-222222222222", provider: "bkash", amount_minor: 125000, currency: "BDT"}
  defp ex_refund, do: %{intent_id: "int_01HZ…", refunded_amount_minor: 50000, return_id: "ret_01HZ…"}
  defp ex_payout, do: %{shopkeeper_id: "22222222-2222-4222-8222-222222222222", method: "bank_transfer", destination: "BD-BANK-ACC-0001234567"}
  defp ex_commission, do: %{scope: "category", scope_id: "33333333-3333-4333-8333-333333333333", percent_basis_points: 250, flat_minor: 0}
  defp ex_intent_dto, do: %{id: "int_01HZ…", order_id: "ord_01HZ…", customer_id: "11111111-1111-4111-8111-111111111111", shopkeeper_id: "22222222-2222-4222-8222-222222222222", provider: "bkash", amount_minor: 125000, currency: "BDT", state: "pending", provider_intent_id: "bkash_TR0011223344", provider_redirect_url: "https://sandbox.bkash/checkout/…", created_at: "2026-06-20T10:15:30Z", settled_at: nil}

  defp description do
    i = identity()
    """
    **service_name**: `#{i[:service_name]}` &nbsp;|&nbsp; **code_version**: `#{i[:code_version]}` &nbsp;|&nbsp; **env_version**: `#{i[:env_version]}` &nbsp;|&nbsp; **tenant**: `#{i[:tenant]}` &nbsp;|&nbsp; **env**: `#{i[:env]}`

    **09-payment** — payment intents, settlements, refunds, COD ledger, payouts (Elixir 1.20 / Phoenix 1.8).
    Webhooks are HMAC-SHA256 verified over the raw body and `(provider, event_id)` replay-fenced. Intents are
    idempotent by `order_id`. A RabbitMQ worker drains `payout.execute`. Emits `payment.*` / `refund.processed`
    via the transactional outbox. Money is integer **paisa** (`amount_minor`).

    ### How to test
    1. Click **Authorize** and paste a Bearer **access token** from the auth service
       (`POST /api/v1/auth/login/request` → `/login/verify`). Customer reads (`/intents/me`, `/intents/{id}`)
       need a user token; refunds, payouts and commission rates need an **admin** token.
    2. `POST /intents` is **internal** — it is called by 13-order with the `x-internal-token` header, not a
       Bearer JWT. Authorize via the **InternalToken** scheme to try it.
    3. `POST /webhooks/{provider}` is public but requires a valid `x-signature` HMAC header over the raw body.
    4. All amounts are integer **paisa** (e.g. `125000` = 1,250.00 BDT). All errors use the shared envelope
       `{error:{code,message,request_id,details}}` with lowercase snake-case codes.
    """
  end

  defp build do
    bearer = [%{"HTTPBearer" => []}]
    internal = [%{"InternalToken" => []}]
    auth401 = err(401, "token_invalid", "token missing or invalid")
    intent_ex = ex_intent_dto()
    %{
      openapi: "3.0.3",
      info: %{
        title: "DOKANDAR Payment Service",
        version: Config.code_version(),
        description: description(),
        contact: %{name: "DOKANDAR Platform", url: "https://dokandar.com.bd", email: "api@dokandar.com.bd"},
        license: %{name: "Proprietary"}
      },
      servers: [
        %{url: "https://api.dokandar.com.bd", description: "prod"},
        %{url: "http://localhost:10009", description: "local"}
      ],
      tags: [
        %{name: "intents", description: "Payment intents (create, list, fetch) — idempotent by order_id"},
        %{name: "refunds", description: "Refund processing (admin)"},
        %{name: "payouts", description: "Seller payouts via the RabbitMQ payout worker (admin / own)"},
        %{name: "cod", description: "Cash-on-delivery ledger (admin / own)"},
        %{name: "commission", description: "Commission-rate configuration (admin)"},
        %{name: "webhooks", description: "Provider settlement webhooks (HMAC-SHA256, replay-fenced)"},
        %{name: "ops", description: "Operational contract: /ready /health /data /metrics"}
      ],
      components: %{
        securitySchemes: %{
          "HTTPBearer" => %{type: "http", scheme: "bearer", bearerFormat: "JWT", description: "RS256 token from 01-auth"},
          "InternalToken" => %{type: "apiKey", in: "header", name: "x-internal-token", description: "INTERNAL_SERVICE_TOKEN (13-order → payment)"}},
        schemas: %{
          "CreateIntentBody" => %{type: "object", required: ["order_id", "customer_id", "provider", "amount_minor"], example: ex_intent(), properties: %{
            order_id: %{type: "string", description: "opaque 13-order id; intents are idempotent by this value"},
            customer_id: %{type: "string", description: "opaque auth user id"},
            shopkeeper_id: %{type: "string", description: "opaque seller id (optional)"},
            provider: %{type: "string", enum: ~w(bkash nagad rocket sslcommerz stripe bank_transfer wallet cod), description: "settlement provider"},
            amount_minor: %{type: "integer", minimum: 0, description: "amount in paisa (1 BDT = 100)"},
            currency: %{type: "string", default: "BDT", description: "ISO-4217; BDT only today"}}},
          "RefundBody" => %{type: "object", required: ["intent_id", "refunded_amount_minor"], example: ex_refund(), properties: %{
            intent_id: %{type: "string", description: "intent to refund against"},
            refunded_amount_minor: %{type: "integer", minimum: 1, description: "amount in paisa, > 0"},
            return_id: %{type: "string", description: "opaque return/RMA id (optional)"}}},
          "PayoutBody" => %{type: "object", required: ["shopkeeper_id", "destination"], example: ex_payout(), properties: %{
            shopkeeper_id: %{type: "string", description: "opaque seller id"},
            method: %{type: "string", description: "payout rail (e.g. bank_transfer)"},
            destination: %{type: "string", description: "non-empty destination account/handle"}}},
          "CommissionRateBody" => %{type: "object", required: ["scope", "percent_basis_points"], example: ex_commission(), properties: %{
            scope: %{type: "string", enum: ~w(platform_default category shopkeeper), description: "rate scope"},
            scope_id: %{type: "string", description: "category/shopkeeper id when scope is not platform_default"},
            percent_basis_points: %{type: "integer", minimum: 0, maximum: 10000, description: "basis points, 0..10000 (10000 = 100%)"},
            flat_minor: %{type: "integer", minimum: 0, description: "optional flat fee in paisa"}}},
          "IntentDto" => %{type: "object", example: intent_ex, properties: %{
            id: s("string"), order_id: s("string"), customer_id: s("string"), shopkeeper_id: s("string"),
            provider: s("string"), amount_minor: %{type: "integer", description: "paisa"}, currency: s("string"),
            state: %{type: "string", description: "intent state (e.g. pending, settled, failed)"},
            provider_intent_id: s("string"), provider_redirect_url: s("string"),
            created_at: %{type: "string", format: "date-time"}, settled_at: %{type: "string", format: "date-time", nullable: true}}},
          "IntentList" => %{type: "array", items: ref("IntentDto")},
          "ErrorEnvelope" => %{type: "object", properties: %{error: %{type: "object", properties: %{
            code: %{type: "string", description: "lowercase snake-case machine code", example: "invalid_request"},
            message: s("string"),
            request_id: %{type: "string", description: "honour-or-mint x-request-id"},
            details: %{type: "object", additionalProperties: true}}}}}}},
      paths: %{
        "/api/v1/payment/intents" => %{"post" => op(%{
          tag: "intents", id: "createIntent", desc: "Internal endpoint (13-order). Authenticated with x-internal-token, not a Bearer JWT. Idempotent by order_id.",
          summary: "Create a payment intent (internal, idempotent by order_id)", sec: internal,
          body: "CreateIntentBody", body_ex: ex_intent(),
          responses: Map.merge(ok(201, "created", "IntentDto", intent_ex), Map.merge(err(401, "unauthorized", "x-internal-token missing or invalid"), err(422, "invalid_request", "amount_minor must be >= 0")))})},
        "/api/v1/payment/intents/me" => %{"get" => op(%{
          tag: "intents", id: "listMyIntents", summary: "List my payment intents", sec: bearer,
          responses: Map.merge(ok(200, "intent list (newest first)", "IntentList", [intent_ex]), auth401)})},
        "/api/v1/payment/intents/{id}" => %{"get" => op(%{
          tag: "intents", id: "getIntent", summary: "Get a payment intent by id", sec: bearer,
          params: [path_p("id", "int_01HZ…", "intent id")],
          responses: Map.merge(ok(200, "intent", "IntentDto", intent_ex), Map.merge(auth401, Map.merge(err(403, "forbidden", "not the intent owner"), err(404, "not_found", "intent not found"))))})},
        "/api/v1/payment/refunds" => %{"post" => op(%{
          tag: "refunds", id: "createRefund", summary: "Process a refund (admin)", sec: bearer,
          body: "RefundBody", body_ex: ex_refund(),
          responses: Map.merge(ok(200, "refund result"), Map.merge(auth401, Map.merge(err(403, "forbidden", "admin role required"), Map.merge(err(404, "not_found", "intent not found"), err(422, "invalid_request", "refunded_amount_minor must be > 0")))))})},
        "/api/v1/payment/payouts" => %{
          "post" => op(%{
            tag: "payouts", id: "createPayout", summary: "Create a payout (admin)", sec: bearer,
            body: "PayoutBody", body_ex: ex_payout(),
            responses: Map.merge(ok(200, "payout queued"), Map.merge(err(400, "payout_rejected", "payout could not be created"), Map.merge(auth401, Map.merge(err(403, "forbidden", "admin role required"), err(422, "invalid_request", "destination required")))))}),
          "get" => op(%{
            tag: "payouts", id: "listPayouts", summary: "List payouts (admin: any seller; user: own)", sec: bearer,
            params: [query_p("shopkeeper_id", "string", false, "22222222-2222-4222-8222-222222222222", "admin-only filter; ignored for non-admins")],
            responses: Map.merge(ok(200, "payout list"), auth401)})},
        "/api/v1/payment/cod-ledger" => %{"get" => op(%{
          tag: "cod", id: "listCodLedger", summary: "Unsettled COD ledger (admin: any seller; user: own)", sec: bearer,
          params: [query_p("shopkeeper_id", "string", false, "22222222-2222-4222-8222-222222222222", "admin-only filter; ignored for non-admins")],
          responses: Map.merge(ok(200, "unsettled COD entries"), auth401)})},
        "/api/v1/payment/commission-rates" => %{
          "get" => op(%{
            tag: "commission", id: "listCommissionRates", summary: "List commission rates (admin)", sec: bearer,
            responses: Map.merge(ok(200, "commission-rate list"), Map.merge(auth401, err(403, "forbidden", "admin role required")))}),
          "post" => op(%{
            tag: "commission", id: "createCommissionRate", summary: "Create a commission rate (admin)", sec: bearer,
            body: "CommissionRateBody", body_ex: ex_commission(),
            responses: Map.merge(ok(200, "created commission rate"), Map.merge(auth401, Map.merge(err(403, "forbidden", "admin role required"), err(422, "invalid_request", "percent_basis_points must be 0..10000"))))})},
        "/api/v1/payment/webhooks/{provider}" => %{"post" => op(%{
          tag: "webhooks", id: "providerWebhook",
          desc: "Public endpoint. The raw request body is HMAC-SHA256 verified against the x-signature header and (provider,event_id) replay-fenced.",
          summary: "Provider settlement webhook (HMAC-SHA256, replay-fenced)",
          params: [
            path_p("provider", "bkash", "settlement provider"),
            %{name: "x-signature", in: "header", required: true, schema: %{type: "string"}, description: "HMAC-SHA256 of the raw body"}],
          responses: Map.merge(ok(200, "accepted"), Map.merge(err(400, "invalid_signature", "signature missing or invalid"), err(409, "replayed", "duplicate (provider,event_id)")))})},
        "/ready" => %{"get" => op(%{tag: "ops", id: "getReady", summary: "Readiness probe (Postgres only)",
          responses: Map.merge(ok(200, "ready"), err(503, "not_ready", "a traffic-gating dependency is down"))})},
        "/health" => %{"get" => op(%{tag: "ops", id: "getHealth", summary: "Full health + dependency diagnostics",
          responses: Map.merge(ok(200, "healthy"), err(503, "unhealthy", "a core dependency is down"))})},
        "/data" => %{"get" => op(%{tag: "ops", id: "getData", summary: "Tenant data snapshot (identity + read-only snapshot)",
          responses: Map.merge(ok(200, "snapshot"), err(404, "no_snapshot", "snapshot not present for tenant"))})},
        "/metrics" => %{"get" => op(%{tag: "ops", id: "getMetrics", summary: "Prometheus metrics (RED + payment_outbox_pending)",
          responses: ok(200, "Prometheus text exposition")})}}}
  end

  defp html do
    """
    <!doctype html><html><head><meta charset="utf-8"><title>09-payment API</title>
    <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"></head>
    <body><div id="swagger-ui"></div>
    <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
    <script>window.onload=function(){SwaggerUIBundle({url:'/openapi.json',dom_id:'#swagger-ui',deepLinking:true,persistAuthorization:true})}</script>
    </body></html>
    """
  end
end
