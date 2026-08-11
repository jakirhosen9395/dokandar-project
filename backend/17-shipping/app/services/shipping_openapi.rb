# Hand-written OpenAPI document (the Go/PHP/Ruby hand-spec stacks own this) + a tiny
# Swagger-UI page. Every served business route appears here (§6, §16-h).
module ShippingOpenapi
  module_function

  def document
    i = ShippingSettings.identity
    desc =
      "**service_name**: `#{i[:service_name]}` &nbsp;|&nbsp; **code_version**: `#{i[:code_version]}` " \
      "&nbsp;|&nbsp; **env_version**: `#{i[:env_version]}` &nbsp;|&nbsp; **tenant**: `#{i[:tenant]}` " \
      "&nbsp;|&nbsp; **env**: `#{i[:env]}`\n\n" \
      "**17-shipping** — last-mile fulfilment: courier selection + failover, consignment booking, " \
      "signed courier webhooks, and Neo4j road-graph routing (zone-table fallback). " \
      "gRPC `Shipping.QuoteDelivery` serves checkout; this REST surface twins it.\n\n" \
      "Pretty-JSON (indent 2, literal UTF-8). Errors use the platform envelope " \
      "`{error:{code,message,request_id,details}}` with stable lowercase_snake codes.\n\n" \
      "### How to test\n" \
      "1. Click **Authorize** and paste a Bearer **access token** from the auth service " \
      "(`POST /api/v1/auth/login/request` → `/login/verify`). All `/shipments`, `/quote`, and `/admin/*` " \
      "routes require it; admin routes additionally need an `admin` role.\n" \
      "2. `POST /shipments` requires a unique **`Idempotency-Key`** header — change it on reruns " \
      "(a repeat returns `409 already_booked`).\n" \
      "3. `POST /webhooks/{courier}` is **not** JWT-authed — it is verified by a constant-time " \
      "**`X-Courier-Signature`** header (courier shared secret), so it is omitted from Authorize."

    {
      openapi: "3.0.3",
      info: {
        title: "DOKANDAR Shipping Service",
        version: i[:code_version],
        description: desc,
        contact: { name: "DOKANDAR Platform", url: "https://dokandar.com.bd", email: "api@dokandar.com.bd" },
        license: { name: "Proprietary" },
      },
      servers: [
        { url: "https://api.dokandar.com.bd", description: "prod" },
        { url: "http://localhost:10017", description: "local" },
      ],
      tags: [
        { name: "ops", description: "Operational / contract surface (/ready /health /data /metrics)" },
        { name: "shipments", description: "Consignment booking + tracking" },
        { name: "quotes", description: "Delivery fee / ETA quotes (REST twin of gRPC QuoteDelivery)" },
        { name: "webhooks", description: "Courier status callbacks (signature-authed, not JWT)" },
        { name: "agents", description: "Rural agent administration" },
      ],
      components: {
        securitySchemes: {
          bearerJwt: { type: "http", scheme: "bearer", bearerFormat: "JWT",
                       description: "RS256 access token minted by 01-auth" },
        },
        schemas: {
          ShipmentCreate: { type: "object", required: %w[sub_order_id address_tier],
            properties: {
              sub_order_id: { type: "string", format: "uuid", description: "owning sub-order (one shipment per shop sub-order)",
                              example: "11111111-1111-4111-8111-111111111111" },
              address_tier: { type: "string", enum: %w[city district upazila union],
                              description: "delivery address granularity (drives courier selection + fee)", example: "upazila" },
              upazila_code: { type: "string", description: "BD upazila code (required for upazila/union tiers + rural routing)", example: "30-85" },
              cod_amount_minor: { type: "integer", description: "cash-on-delivery amount in paisa (integer minor units); 0 for prepaid", example: 145000 },
            } },
          ShipmentDto: { type: "object",
            properties: {
              id: { type: "string", description: "shipment id" },
              sub_order_id: { type: "string", format: "uuid" },
              status: { type: "string", enum: %w[pending booked in_transit delivered failed_delivery returned cancelled],
                        description: "lifecycle status" },
              courier: { type: "string", description: "selected courier code", example: "pathao" },
              tracking_code: { type: "string", description: "courier tracking code", example: "PTH-7H3K9" },
            } },
          Quote: { type: "object",
            properties: {
              courier: { type: "string", description: "selected courier code", example: "pathao" },
              fee_minor: { type: "integer", description: "delivery fee in paisa (integer minor units)", example: 6000 },
              eta_hours: { type: "integer", description: "estimated delivery time in hours", example: 48 },
              distance_km: { type: "number", format: "double", description: "routed distance in km", example: 12.4 },
              source: { type: "string", enum: %w[graph zone_table], description: "distance source: Neo4j road-graph or zone-table fallback", example: "graph" },
            } },
          ErrorEnvelope: { type: "object", required: %w[error],
            properties: { error: { type: "object", required: %w[code message request_id],
              properties: {
                code: { type: "string", description: "stable lowercase_snake machine code", example: "not_found" },
                message: { type: "string", description: "human-readable (scrubbed) message", example: "shipment not found" },
                request_id: { type: "string", description: "honour-or-mint x-request-id", example: "11111111-1111-4111-8111-111111111111" },
                details: { type: "object", additionalProperties: true, description: "optional structured context", example: {} },
              } } } },
        },
      },
      paths: {
        # ── ops / contract surface ───────────────────────────────────────────────────
        "/ready" => {
          get: { operationId: "opsReady", tags: ["ops"], summary: "Readiness probe (postgres only)",
            responses: { "200" => { description: "ready" }, "503" => { description: "not_ready" } } } },
        "/health" => {
          get: { operationId: "opsHealth", tags: ["ops"], summary: "Full health + dependency checks",
            responses: { "200" => { description: "healthy" }, "503" => { description: "unhealthy" } } } },
        "/data" => {
          get: { operationId: "opsData", tags: ["ops"], summary: "Identity block + host snapshot",
            responses: { "200" => { description: "snapshot" }, "404" => err } } },
        "/metrics" => {
          get: { operationId: "opsMetrics", tags: ["ops"], summary: "Prometheus metrics (text exposition)",
            responses: { "200" => { description: "exposition" } } } },

        # ── shipments ────────────────────────────────────────────────────────────────
        "/api/v1/shipping/shipments" => {
          post: { operationId: "createShipment", tags: ["shipments"],
            summary: "Create a shipment (Idempotency-Key required)",
            description: "Books a consignment for a sub-order and selects a courier. The `Idempotency-Key` " \
                         "header is mandatory; a repeat of the same key returns `409 already_booked`.",
            security: [{ bearerJwt: [] }],
            parameters: [
              { name: "Idempotency-Key", in: "header", required: true,
                schema: { type: "string" }, description: "unique key making create at-least-once effectively-once",
                example: "idem-7f3a2b10" },
            ],
            requestBody: { required: true, content: { "application/json" => {
              schema: { "$ref" => "#/components/schemas/ShipmentCreate" },
              example: { sub_order_id: "11111111-1111-4111-8111-111111111111", address_tier: "upazila",
                         upazila_code: "30-85", cod_amount_minor: 145000 } } } },
            responses: {
              "201" => ok_ref("ShipmentDto", "created"),
              "400" => err_d("missing_idempotency_key"),
              "401" => err_d("token_missing / token_invalid"),
              "409" => err_d("already_booked"),
              "422" => err_d("invalid_request"),
            } } },
        "/api/v1/shipping/shipments/{id}" => {
          get: { operationId: "getShipment", tags: ["shipments"], summary: "Shipment + tracking by id",
            security: [{ bearerJwt: [] }],
            parameters: [{ name: "id", in: "path", required: true, schema: { type: "string" },
                          description: "shipment id", example: "ship_01H..." }],
            responses: { "200" => ok_ref("ShipmentDto", "shipment"),
                         "401" => err_d("token_missing / token_invalid"), "404" => err_d("not_found") } } },
        "/api/v1/shipping/shipments/by-order/{sub_order_id}" => {
          get: { operationId: "getShipmentByOrder", tags: ["shipments"], summary: "Latest shipment for a sub-order",
            security: [{ bearerJwt: [] }],
            parameters: [{ name: "sub_order_id", in: "path", required: true,
                          schema: { type: "string", format: "uuid" }, description: "owning sub-order id",
                          example: "11111111-1111-4111-8111-111111111111" }],
            responses: { "200" => ok_ref("ShipmentDto", "shipment"),
                         "401" => err_d("token_missing / token_invalid"), "404" => err_d("not_found") } } },

        # ── quotes ───────────────────────────────────────────────────────────────────
        "/api/v1/shipping/quote" => {
          get: { operationId: "getQuote", tags: ["quotes"],
            summary: "Delivery quote (REST twin of the gRPC QuoteDelivery)",
            security: [{ bearerJwt: [] }],
            parameters: [
              { name: "tier", in: "query", required: true,
                schema: { type: "string", enum: %w[city district upazila union] },
                description: "delivery address granularity (required)", example: "upazila" },
              { name: "weight", in: "query", required: false,
                schema: { type: "integer", minimum: 0, default: 0 },
                description: "package weight in grams (affects fee tier)", example: 1200 },
              { name: "upazila", in: "query", required: false,
                schema: { type: "string" }, description: "BD upazila code (enables road-graph routing)", example: "30-85" },
            ],
            responses: { "200" => ok_ref("Quote", "quote"),
                         "401" => err_d("token_missing / token_invalid"),
                         "422" => err_d("invalid_request / no_courier") } } },

        # ── webhooks (courier-signature auth, NOT JWT) ───────────────────────────────
        "/api/v1/shipping/webhooks/{courier}" => {
          post: { operationId: "receiveCourierWebhook", tags: ["webhooks"],
            summary: "Courier status callback (X-Courier-Signature auth, not JWT)",
            description: "Authenticated by a constant-time `X-Courier-Signature` header (courier shared " \
                         "secret), not a Bearer token. Idempotent — a repeat or an unmatched shipment is a 200 no-op.",
            parameters: [
              { name: "courier", in: "path", required: true, schema: { type: "string" },
                description: "courier code (selects the signing secret)", example: "pathao" },
              { name: "X-Courier-Signature", in: "header", required: true, schema: { type: "string" },
                description: "courier signature, compared constant-time" },
            ],
            responses: { "200" => { description: "accepted (idempotent)" }, "403" => err_d("signature_invalid") } } },

        # ── rural agents (admin) ─────────────────────────────────────────────────────
        "/api/v1/shipping/admin/agents" => {
          get: { operationId: "listAgents", tags: ["agents"], summary: "List active rural agents",
            security: [{ bearerJwt: [] }],
            parameters: [
              { name: "upazila", in: "query", required: false, schema: { type: "string" },
                description: "filter by BD upazila code", example: "30-85" },
            ],
            responses: { "200" => { description: "{agents:[…]}" }, "401" => err_d("token_missing / token_invalid") } },
          post: { operationId: "createAgent", tags: ["agents"], summary: "Add a rural agent (admin)",
            security: [{ bearerJwt: [] }],
            requestBody: { required: true, content: { "application/json" => {
              schema: { type: "object", required: %w[upazila_code name],
                properties: {
                  upazila_code: { type: "string", description: "BD upazila code served by the agent", example: "30-85" },
                  name: { type: "string", description: "agent display name", example: "Rural Hub Gulshan" },
                  phone: { type: "string", description: "contact phone (optional)", example: "+8801712345678" },
                } },
              example: { upazila_code: "30-85", name: "Rural Hub Gulshan", phone: "+8801712345678" } } } },
            responses: {
              "201" => { description: "created" },
              "401" => err_d("token_missing / token_invalid"),
              "403" => err_d("insufficient_role"),
              "422" => err_d("invalid_request"),
            } } },
      },
    }
  end

  # Error response (generic) + a labelled variant carrying the contract code in its description.
  def err = { description: "error", content: { "application/json" => { schema: { "$ref" => "#/components/schemas/ErrorEnvelope" } } } }
  def err_d(desc) = { description: desc, content: { "application/json" => { schema: { "$ref" => "#/components/schemas/ErrorEnvelope" } } } }
  def ok_ref(name, desc = "ok") = { description: desc, content: { "application/json" => { schema: { "$ref" => "#/components/schemas/#{name}" } } } }

  def swagger_ui_html
    <<~HTML
      <!doctype html><html><head><meta charset="utf-8"><title>17-shipping API</title>
      <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5/swagger-ui.css"></head>
      <body><div id="swagger-ui"></div>
      <script src="https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
      <script>window.onload=()=>{SwaggerUIBundle({url:"/openapi.json",dom_id:"#swagger-ui",deepLinking:true,persistAuthorization:true});};</script>
      </body></html>
    HTML
  end
end
