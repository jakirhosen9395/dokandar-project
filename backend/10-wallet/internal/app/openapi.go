package app

import "github.com/dokandar/dokandar-wallet/internal/config"

// openapiSpec is the hand-built OpenAPI 3.0.3 document. CI invariant: every
// served REST route appears here (Go is a hand-spec stack). info.version is the
// CODE_VERSION value injected by the caller via config.CodeVersion().
func openapiSpec(serviceName string) map[string]any {
	jsonObj := func(props map[string]any, required ...string) map[string]any {
		m := map[string]any{"type": "object", "properties": props}
		if len(required) > 0 {
			m["required"] = required
		}
		return m
	}
	strProp := map[string]any{"type": "string"}

	walletSchema := jsonObj(map[string]any{
		"user_id":         map[string]any{"type": "string", "format": "uuid", "description": "opaque auth user id (the wallet owner)"},
		"currency":        map[string]any{"type": "string", "description": "ISO-4217; always BDT", "example": "BDT"},
		"status":          map[string]any{"type": "string", "enum": []string{"active", "frozen", "closed"}, "description": "wallet lifecycle state"},
		"balance_minor":   map[string]any{"type": "integer", "format": "int64", "description": "ledger balance in paisa (minor units); capped at 5,000,000 (=50,000 BDT)"},
		"available_minor": map[string]any{"type": "integer", "format": "int64", "description": "balance minus holds, in paisa"},
		"version":         map[string]any{"type": "integer", "format": "int64", "description": "optimistic-lock row version"},
	})
	entrySchema := jsonObj(map[string]any{
		"id":              map[string]any{"type": "string", "format": "uuid"},
		"wallet_user_id":  map[string]any{"type": "string", "format": "uuid"},
		"debit_minor":     map[string]any{"type": "integer", "format": "int64", "description": "paisa debited (XOR with credit_minor)"},
		"credit_minor":    map[string]any{"type": "integer", "format": "int64", "description": "paisa credited (XOR with debit_minor)"},
		"kind":            map[string]any{"type": "string", "description": "ledger entry kind", "example": "cashback"},
		"order_id":        map[string]any{"type": "string", "format": "uuid", "nullable": true, "description": "originating order id, if any"},
		"idempotency_key": map[string]any{"type": "string", "description": "unique key making at-least-once effectively-once"},
		"posted_at":       map[string]any{"type": "string", "format": "date-time", "description": "RFC-3339 UTC"},
	})
	ruleSchema := jsonObj(map[string]any{
		"id":                 map[string]any{"type": "string", "format": "uuid"},
		"trigger":            map[string]any{"type": "string", "description": "event that fires the rule", "example": "order_delivered"},
		"funded_by":          map[string]any{"type": "string", "description": "who funds the reward (platform/seller)", "example": "platform"},
		"reward_kind":        map[string]any{"type": "string", "enum": []string{"percent", "flat"}, "description": "percent of subtotal or a flat paisa amount"},
		"reward_value":       map[string]any{"type": "integer", "format": "int64", "description": "basis points if percent, else paisa"},
		"reward_cap_minor":   map[string]any{"type": "integer", "format": "int64", "nullable": true, "description": "max reward in paisa"},
		"min_subtotal_minor": map[string]any{"type": "integer", "format": "int64", "nullable": true, "description": "min order subtotal in paisa to qualify"},
		"max_per_user":       map[string]any{"type": "integer", "description": "lifetime cap per user"},
	})

	// Request-body schemas (reused as components, $ref'd from operations).
	topupReqSchema := jsonObj(map[string]any{
		"amount_minor": map[string]any{"type": "integer", "format": "int64", "minimum": 1, "description": "top-up amount in paisa (minor units)", "example": 50000},
	}, "amount_minor")
	debitReqSchema := jsonObj(map[string]any{
		"user_id":         map[string]any{"type": "string", "format": "uuid", "description": "wallet owner"},
		"amount_minor":    map[string]any{"type": "integer", "format": "int64", "minimum": 1, "description": "paisa to debit"},
		"idempotency_key": map[string]any{"type": "string", "description": "caller-supplied, makes the debit effectively-once"},
		"order_id":        map[string]any{"type": "string", "format": "uuid", "nullable": true, "description": "originating order id (optional)"},
	}, "user_id", "amount_minor", "idempotency_key")
	creditReqSchema := jsonObj(map[string]any{
		"user_id":         map[string]any{"type": "string", "format": "uuid", "description": "wallet owner"},
		"amount_minor":    map[string]any{"type": "integer", "format": "int64", "minimum": 1, "description": "paisa to credit"},
		"idempotency_key": map[string]any{"type": "string", "description": "caller-supplied, makes the credit effectively-once"},
		"kind":            map[string]any{"type": "string", "description": "credit reason (e.g. cashback, refund, reversal)", "example": "cashback"},
		"order_id":        map[string]any{"type": "string", "format": "uuid", "nullable": true, "description": "originating order id (optional)"},
	}, "user_id", "amount_minor", "idempotency_key")
	// ErrorEnvelope — the single shared platform error shape
	// {error:{code,message,request_id,details}}. $ref'd on every 4xx/5xx.
	errorSchema := jsonObj(map[string]any{
		"error": jsonObj(map[string]any{
			"code":       map[string]any{"type": "string", "description": "stable machine code (lowercase snake_case)", "example": "validation_error"},
			"message":    map[string]any{"type": "string", "description": "human-readable, scrubbed (never leaks 5xx internals)", "example": "amount_minor must be a positive integer"},
			"request_id": map[string]any{"type": "string", "description": "honour-or-mint x-request-id echo", "example": "11111111-1111-4111-8111-111111111111"},
			"details":    map[string]any{"type": "object", "description": "optional structured context", "additionalProperties": true},
		}, "code", "message", "request_id"),
	}, "error")

	ref := func(name string) map[string]any {
		return map[string]any{"$ref": "#/components/schemas/" + name}
	}
	jsonContent := func(schema map[string]any) map[string]any {
		return map[string]any{"application/json": map[string]any{"schema": schema}}
	}
	jsonContentEx := func(schema map[string]any, example map[string]any) map[string]any {
		return map[string]any{"application/json": map[string]any{"schema": schema, "example": example}}
	}
	resp := func(desc string, schema map[string]any) map[string]any {
		r := map[string]any{"description": desc}
		if schema != nil {
			r["content"] = jsonContent(schema)
		}
		return r
	}
	errResp := func(desc string) map[string]any { return resp(desc, ref("ErrorEnvelope")) }

	bearer := []map[string]any{{"bearerJwt": []any{}}}
	internal := []map[string]any{{"internalToken": []any{}}}

	// Example bodies (BDT amounts are integer paisa / minor units).
	walletEx := map[string]any{
		"user_id": "11111111-1111-4111-8111-111111111111", "currency": "BDT",
		"status": "active", "balance_minor": 150000, "available_minor": 150000, "version": 3,
	}
	topupEx := map[string]any{"amount_minor": 50000}
	debitEx := map[string]any{
		"user_id": "11111111-1111-4111-8111-111111111111", "amount_minor": 25000,
		"idempotency_key": "order-9c1f-debit-1", "order_id": "22222222-2222-4222-8222-222222222222",
	}
	creditEx := map[string]any{
		"user_id": "11111111-1111-4111-8111-111111111111", "amount_minor": 25000,
		"idempotency_key": "order-9c1f-credit-1", "kind": "cashback",
		"order_id": "22222222-2222-4222-8222-222222222222",
	}

	return map[string]any{
		"openapi": "3.0.3",
		"info": map[string]any{
			"title":   "DOKANDAR Wallet Service",
			"version": config.CodeVersion(),
			"description": "**service_name**: `" + serviceName + "` &nbsp;|&nbsp; **code_version**: `" + config.CodeVersion() + "` &nbsp;|&nbsp; " +
				"**env_version / tenant / env**: see `GET /data` identity block.\n\n" +
				"Double-entry wallet ledger: top-ups, cashback rules, and east-west debit/credit. " +
				"Money is integer **paisa** (minor units); a wallet is capped at 5,000,000 paisa (50,000 BDT).\n\n" +
				"### How to test\n" +
				"1. Click **Authorize** and paste a Bearer **access token** from the auth service " +
				"(`POST /api/v1/auth/login/request` → `/login/verify`). Customer routes (`/me`, `/me/entries`, `/me/topup`) need it.\n" +
				"2. `GET /api/v1/wallet/cashback-rules` is public (no token).\n" +
				"3. East-west routes (`/debit`, `/credit`, `/balance/{user_id}`) require the shared **`x-internal-token`** header, not a JWT.\n" +
				"4. `POST /me/topup` requires a unique **`Idempotency-Key`** header — reusing one returns the original wallet (effectively-once).",
			"contact": map[string]any{
				"name":  "DOKANDAR Platform",
				"url":   "https://dokandar.com.bd",
				"email": "api@dokandar.com.bd",
			},
			"license": map[string]any{"name": "Proprietary"},
		},
		"servers": []map[string]any{
			{"url": "https://api.dokandar.com.bd", "description": "prod"},
			{"url": "http://localhost:10010", "description": "local"},
		},
		"tags": []map[string]any{
			{"name": "ops", "description": "Operational / contract surface (/ready /health /data /metrics /docs /openapi.json)"},
			{"name": "wallet", "description": "Customer wallet: balance, ledger history, top-ups"},
			{"name": "cashback", "description": "Active cashback rules (public read)"},
			{"name": "ledger", "description": "East-west double-entry debit/credit + balance reads (x-internal-token)"},
		},
		"components": map[string]any{
			"securitySchemes": map[string]any{
				"bearerJwt": map[string]any{
					"type": "http", "scheme": "bearer", "bearerFormat": "JWT",
				},
				"internalToken": map[string]any{
					"type": "apiKey", "in": "header", "name": "x-internal-token",
				},
			},
			"schemas": map[string]any{
				"Wallet":        walletSchema,
				"Entry":         entrySchema,
				"CashbackRule":  ruleSchema,
				"TopupRequest":  topupReqSchema,
				"DebitRequest":  debitReqSchema,
				"CreditRequest": creditReqSchema,
				"ErrorEnvelope": errorSchema,
			},
		},
		"paths": map[string]any{
			"/ready": map[string]any{"get": map[string]any{
				"tags":        []string{"ops"},
				"operationId": "getReady",
				"summary":     "Readiness probe (gates on Postgres only)",
				"description": "LB/readiness gate. 200 only when Postgres (system-of-record) is reachable; degradable deps never gate.",
				"responses": map[string]any{
					"200": resp("ready", nil), "503": resp("not_ready", nil),
				},
			}},
			"/health": map[string]any{"get": map[string]any{
				"tags":        []string{"ops"},
				"operationId": "getHealth",
				"summary":     "Full diagnostics (postgres, redis, kafka, mongo_logs, elasticsearch + observability)",
				"description": "Full diagnostics over all deps plus an observability block. gRPC peer checks are diagnostic-only and never flip status.",
				"responses": map[string]any{
					"200": resp("healthy", nil), "503": resp("unhealthy", nil),
				},
			}},
			"/data": map[string]any{"get": map[string]any{
				"tags":        []string{"ops"},
				"operationId": "getData",
				"summary":     "Tenant snapshot + identity block",
				"description": "Identity block prepended to the read-only data/<tenant>/result.json snapshot (not live DB introspection).",
				"responses": map[string]any{
					"200": resp("snapshot", nil), "404": errResp("no_snapshot"), "500": errResp("snapshot_parse_failed"),
				},
			}},
			"/metrics": map[string]any{"get": map[string]any{
				"tags":        []string{"ops"},
				"operationId": "getMetrics",
				"summary":     "Prometheus exposition",
				"description": "Prometheus text exposition (RED + service counters + wallet_outbox_pending gauge). Closed-set labels only.",
				"responses":   map[string]any{"200": resp("prometheus text", nil)},
			}},
			"/docs": map[string]any{"get": map[string]any{
				"tags":        []string{"ops"},
				"operationId": "getDocs",
				"summary":     "Swagger UI",
				"responses":   map[string]any{"200": resp("html", nil)},
			}},
			"/openapi.json": map[string]any{"get": map[string]any{
				"tags":        []string{"ops"},
				"operationId": "getOpenapi",
				"summary":     "This document",
				"responses":   map[string]any{"200": resp("openapi", nil)},
			}},
			"/api/v1/wallet/me": map[string]any{"get": map[string]any{
				"tags":        []string{"wallet"},
				"operationId": "getMyWallet",
				"summary":     "Get (or auto-create) the caller's wallet",
				"description": "Returns the JWT subject's wallet, creating an empty active wallet on first read.",
				"security":    bearer,
				"responses": map[string]any{
					"200": map[string]any{"description": "wallet", "content": jsonContentEx(ref("Wallet"), walletEx)},
					"401": errResp("token_missing / token_invalid"),
				},
			}},
			"/api/v1/wallet/me/entries": map[string]any{"get": map[string]any{
				"tags":        []string{"wallet"},
				"operationId": "listMyEntries",
				"summary":     "Ledger history (newest first)",
				"description": "Paginated double-entry ledger for the caller's wallet, newest first.",
				"security":    bearer,
				"parameters": []map[string]any{{
					"name": "size", "in": "query", "required": false,
					"description": "page size (newest-first)", "example": 50,
					"schema": map[string]any{"type": "integer", "default": 50, "minimum": 1, "maximum": 200},
				}},
				"responses": map[string]any{
					"200": resp("entries", map[string]any{"type": "array", "items": ref("Entry")}),
					"401": errResp("token_missing / token_invalid"),
				},
			}},
			"/api/v1/wallet/me/topup": map[string]any{"post": map[string]any{
				"tags":        []string{"wallet"},
				"operationId": "topupMyWallet",
				"summary":     "Top up the wallet (Idempotency-Key header required)",
				"description": "Credits the caller's wallet by amount_minor (paisa). Reusing an Idempotency-Key returns the original result (effectively-once). Rejected if it would exceed the 50,000 BDT cap.",
				"security":    bearer,
				"parameters": []map[string]any{{
					"name": "Idempotency-Key", "in": "header", "required": true,
					"description": "unique per logical top-up", "example": "topup-2026-06-20-001",
					"schema": strProp,
				}},
				"requestBody": map[string]any{"required": true, "content": jsonContentEx(ref("TopupRequest"), topupEx)},
				"responses": map[string]any{
					"201": map[string]any{"description": "wallet after top-up", "content": jsonContentEx(ref("Wallet"), walletEx)},
					"400": errResp("missing_idempotency_key"),
					"409": errResp("wallet_max_exceeded"),
					"422": errResp("invalid_request"),
				},
			}},
			"/api/v1/wallet/cashback-rules": map[string]any{"get": map[string]any{
				"tags":        []string{"cashback"},
				"operationId": "listCashbackRules",
				"summary":     "Active cashback rules (public)",
				"description": "Public list of currently-active cashback rules. No authentication required.",
				"responses":   map[string]any{"200": resp("rules", map[string]any{"type": "array", "items": ref("CashbackRule")})},
			}},
			"/api/v1/wallet/debit": map[string]any{"post": map[string]any{
				"tags":        []string{"ledger"},
				"operationId": "debitWallet",
				"summary":     "Debit a wallet (east-west; x-internal-token)",
				"description": "East-west call (used by the order saga). Debits amount_minor from the user's wallet under SERIALIZABLE; idempotency_key makes the debit effectively-once. Requires x-internal-token.",
				"security":    internal,
				"requestBody": map[string]any{"required": true, "content": jsonContentEx(ref("DebitRequest"), debitEx)},
				"responses": map[string]any{
					"200": map[string]any{"description": "wallet after debit", "content": jsonContentEx(ref("Wallet"), walletEx)},
					"401": errResp("unauthorized (missing/invalid x-internal-token)"),
					"409": errResp("insufficient_balance"),
					"422": errResp("invalid_request"),
				},
			}},
			"/api/v1/wallet/credit": map[string]any{"post": map[string]any{
				"tags":        []string{"ledger"},
				"operationId": "creditWallet",
				"summary":     "Credit a wallet (east-west; x-internal-token)",
				"description": "East-west call (cashback, refund, saga compensation). Credits amount_minor to the user's wallet; idempotency_key makes the credit effectively-once. Requires x-internal-token.",
				"security":    internal,
				"requestBody": map[string]any{"required": true, "content": jsonContentEx(ref("CreditRequest"), creditEx)},
				"responses": map[string]any{
					"200": map[string]any{"description": "wallet after credit", "content": jsonContentEx(ref("Wallet"), walletEx)},
					"401": errResp("unauthorized (missing/invalid x-internal-token)"),
					"409": errResp("wallet_max_exceeded"),
					"422": errResp("invalid_request"),
				},
			}},
			"/api/v1/wallet/balance/{user_id}": map[string]any{"get": map[string]any{
				"tags":        []string{"ledger"},
				"operationId": "getWalletBalance",
				"summary":     "Read a wallet balance (east-west; x-internal-token)",
				"description": "East-west balance read by user id. Requires x-internal-token.",
				"security":    internal,
				"parameters": []map[string]any{{
					"name": "user_id", "in": "path", "required": true,
					"description": "wallet owner (auth user id)", "example": "11111111-1111-4111-8111-111111111111",
					"schema": map[string]any{"type": "string", "format": "uuid"},
				}},
				"responses": map[string]any{
					"200": map[string]any{"description": "wallet", "content": jsonContentEx(ref("Wallet"), walletEx)},
					"400": errResp("bad_request"),
					"401": errResp("unauthorized (missing/invalid x-internal-token)"),
				},
			}},
		},
	}
}

const swaggerHTML = `<!doctype html>
<html><head><title>10-wallet API</title>
<meta charset="utf-8"/>
<link rel="stylesheet" href="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui.css">
</head><body><div id="ui"></div>
<script src="https://cdn.jsdelivr.net/npm/swagger-ui-dist@5/swagger-ui-bundle.js"></script>
<script>SwaggerUIBundle({url:"/openapi.json", dom_id:"#ui", deepLinking:true, persistAuthorization:true})</script>
</body></html>`
