package httpx

import (
	"net/http"
	"strings"
)

// The dkd-platform SDK exposes no apidocs package at the pinned v1.3.0 (it first appears at v1.6.0).
// Rather than move the SDK pin, the audit sink hand-rolls the minimal OpenAPI surface in-repo: a
// Bearer securityScheme plus the four operational endpoints. Behaviour matches the platform API
// Documentation Standard (UI at /docs, spec at /swagger/v1/swagger.json).

const swaggerUISrc = "https://cdn.jsdelivr.net/npm/swagger-ui-dist@5.17.14"

// isDocsPath reports whether p is a documentation surface whose CSP must be relaxed to load the UI.
func isDocsPath(p string) bool {
	return p == "/docs" || p == "/swagger/v1/swagger.json"
}

// docsCSP is the relaxed Content-Security-Policy permitting only the Swagger UI CDN assets.
func docsCSP() string {
	return "default-src 'none'; " +
		"script-src 'self' https://cdn.jsdelivr.net 'unsafe-inline'; " +
		"style-src 'self' https://cdn.jsdelivr.net 'unsafe-inline'; " +
		"img-src 'self' data: https://cdn.jsdelivr.net; " +
		"connect-src 'self'"
}

// registerDocs wires the OpenAPI JSON (/swagger/v1/swagger.json) and Swagger UI (/docs).
func registerDocs(mux *http.ServeMux, serviceName string) {
	spec := strings.ReplaceAll(openAPISpec, "{{SERVICE}}", serviceName)
	html := strings.ReplaceAll(swaggerUIHTML, "{{SERVICE}}", serviceName)
	mux.HandleFunc("/swagger/v1/swagger.json", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "application/json")
		_, _ = w.Write([]byte(spec))
	})
	mux.HandleFunc("/docs", func(w http.ResponseWriter, _ *http.Request) {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		_, _ = w.Write([]byte(html))
	})
}

// openAPISpec is a hand-written OpenAPI 3.0.3 document. It intentionally contains the literal
// "version": "v1" and a "Bearer" securityScheme (http/bearer/JWT), plus the operationIds
// Health/Live/Ready/Version, which the docs test and the release evidence assert on.
const openAPISpec = `{
  "openapi": "3.0.3",
  "info": {
    "title": "{{SERVICE}}",
    "version": "v1",
    "description": "DOKANDAR Context #2 — Product Master Data & Catalog (R7 master-data OHS, sole GPID issuer). External REST /v1 surface: {success,data,error,meta} envelope, RFC-7807 problem+json, Idempotency-Key mandatory on unsafe writes, cursor pagination."
  },
  "components": {
    "securitySchemes": {
      "Bearer": {
        "type": "http",
        "scheme": "bearer",
        "bearerFormat": "JWT"
      }
    }
  },
  "security": [ { "Bearer": [] } ],
  "paths": {
    "/health": {
      "get": {
        "operationId": "Health",
        "summary": "Aggregate health probe",
        "security": [],
        "responses": { "200": { "description": "service healthy" } }
      }
    },
    "/live": {
      "get": {
        "operationId": "Live",
        "summary": "Liveness probe",
        "security": [],
        "responses": { "200": { "description": "process alive" } }
      }
    },
    "/ready": {
      "get": {
        "operationId": "Ready",
        "summary": "Readiness probe (green only once Kafka + DB are connected)",
        "security": [],
        "responses": {
          "200": { "description": "ready" },
          "503": { "description": "not ready" }
        }
      }
    },
    "/version": {
      "get": {
        "operationId": "Version",
        "summary": "Build and contract provenance",
        "security": [],
        "responses": { "200": { "description": "version + provenance info" } }
      }
    },
    "/v1/catalog/products": {
      "post": {
        "operationId": "CreateProduct",
        "summary": "Create a Product (mints the GPID — sole issuer, R7). Idempotency-Key required.",
        "parameters": [ { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } } ],
        "responses": { "201": { "description": "created (envelope with product)" }, "400": { "description": "problem+json validation error" }, "409": { "description": "problem+json idempotency conflict" } }
      },
      "get": {
        "operationId": "ListProducts",
        "summary": "List products (cursor pagination only)",
        "parameters": [
          { "name": "cursor", "in": "query", "schema": { "type": "string" } },
          { "name": "limit", "in": "query", "schema": { "type": "integer" } }
        ],
        "responses": { "200": { "description": "envelope with items + meta.page" } }
      }
    },
    "/v1/catalog/products/{gpid}": {
      "get": {
        "operationId": "GetProduct",
        "summary": "Fetch product master data by GPID",
        "parameters": [ { "name": "gpid", "in": "path", "required": true, "schema": { "type": "string" } } ],
        "responses": { "200": { "description": "envelope with product" }, "404": { "description": "problem+json not found" } }
      },
      "patch": {
        "operationId": "UpdateMasterData",
        "summary": "Patch whitelisted master-data fields (namesBn never clearable, GPID immutable). Idempotency-Key required.",
        "parameters": [
          { "name": "gpid", "in": "path", "required": true, "schema": { "type": "string" } },
          { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } }
        ],
        "responses": { "200": { "description": "updated" }, "409": { "description": "problem+json violation/conflict" } }
      }
    },
    "/v1/catalog/products/{gpid}/lifecycle": {
      "patch": {
        "operationId": "ChangeLifecycle",
        "summary": "publish | deprecate (deprecation blocked while active custody passports exist — M5). Idempotency-Key required.",
        "parameters": [
          { "name": "gpid", "in": "path", "required": true, "schema": { "type": "string" } },
          { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } }
        ],
        "responses": { "200": { "description": "lifecycle changed" }, "409": { "description": "problem+json lifecycle violation" } }
      }
    },
    "/v1/catalog/products/{gpid}/price-rules": {
      "post": {
        "operationId": "AddPriceRule",
        "summary": "Add a price rule (int64 poisha; max 50; no same-tier window overlap). Idempotency-Key required.",
        "parameters": [
          { "name": "gpid", "in": "path", "required": true, "schema": { "type": "string" } },
          { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } }
        ],
        "responses": { "201": { "description": "rule added" }, "409": { "description": "problem+json rule rejected" } }
      }
    },
    "/v1/catalog/search": {
      "get": {
        "operationId": "SearchCatalog",
        "summary": "Bangla-first product search (OpenSearch business index only)",
        "parameters": [
          { "name": "q", "in": "query", "required": true, "schema": { "type": "string" } },
          { "name": "limit", "in": "query", "schema": { "type": "integer" } }
        ],
        "responses": { "200": { "description": "envelope with matching documents" }, "503": { "description": "search backend unavailable" } }
      }
    }
  }
}`

// swaggerUIHTML renders the spec via the swagger-ui-dist CDN bundle.
const swaggerUIHTML = `<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>{{SERVICE}} — API Docs</title>
  <link rel="stylesheet" href="` + swaggerUISrc + `/swagger-ui.css">
</head>
<body>
  <div id="swagger-ui"></div>
  <script src="` + swaggerUISrc + `/swagger-ui-bundle.js"></script>
  <script>
    window.ui = SwaggerUIBundle({ url: "/swagger/v1/swagger.json", dom_id: "#swagger-ui" });
  </script>
</body>
</html>`
