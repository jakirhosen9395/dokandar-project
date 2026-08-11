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
    "description": "DOKANDAR Context #3 — Custody & Provenance Ledger (R1 SOLE provenance writer). Event-sourced, per-PPID hash-chained, append-only (CustodyHash Spec v2). Every write carries an Idempotency-Key; every chain is verifiable via /verify."
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
    "/v1/custody/passports": {
      "post": {
        "operationId": "InitializeCustody",
        "summary": "Mint a PPID and seal the genesis event (previousHash empty string). GPID must be PUBLISHED (R7). Idempotency-Key required.",
        "parameters": [ { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } } ],
        "responses": { "201": { "description": "passport created" }, "409": { "description": "problem+json precondition/conflict" } }
      }
    },
    "/v1/custody/passports/{ppid}": {
      "get": {
        "operationId": "GetPassport",
        "summary": "Passport head state",
        "parameters": [ { "name": "ppid", "in": "path", "required": true, "schema": { "type": "string" } } ],
        "responses": { "200": { "description": "envelope with passport" }, "404": { "description": "not found" } }
      }
    },
    "/v1/custody/passports/{ppid}/events": {
      "get": {
        "operationId": "ListPassportEvents",
        "summary": "The full hash-linked event chain for a PPID",
        "parameters": [ { "name": "ppid", "in": "path", "required": true, "schema": { "type": "string" } } ],
        "responses": { "200": { "description": "chain rows with prevHash/eventHash" } }
      }
    },
    "/v1/custody/passports/{ppid}/verify": {
      "get": {
        "operationId": "VerifyChain",
        "summary": "Recompute every CustodyHash (Spec v2) and check linkage + head consistency",
        "parameters": [ { "name": "ppid", "in": "path", "required": true, "schema": { "type": "string" } } ],
        "responses": { "200": { "description": "{verified, detail}" } }
      }
    },
    "/v1/custody/passports/{ppid}/transfer": {
      "post": {
        "operationId": "TransferCustody",
        "summary": "Full-lot transfer (quantity derived, C2). Two authorization modes, mutually exclusive. (1) HUMAN DUAL-SIGNED (BR-005/FR-PASS-010): the releasing custodian (fromHolder=actor_did) AND the receiving custodian (toHolder=cosign_did) must each Ed25519-sign the transfer eventHash; custody does NOT move without both. (2) ATTESTATION-AUTHORITY (C3-F2e; FR-PASS-014/FR-PASS-070): a saga-internal, reference-linked move (e.g. a logistics POD) carries a single attestationSignature by the configured authority over the POD-ATTEST message; accepted ONLY when referenceOrd is non-empty and an authority key is configured. quantity/unit/gpid/previousHash are server-derived (GET the passport). Idempotency-Key required.",
        "parameters": [
          { "name": "ppid", "in": "path", "required": true, "schema": { "type": "string" } },
          { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } }
        ],
        "requestBody": { "required": true, "content": { "application/json": { "schema": {
          "type": "object",
          "required": ["fromHolder","toHolder","toHolderRole","transferredAt"],
          "properties": {
            "fromHolder": { "type": "string", "description": "releasing custodian DID (actor_did); must be the current holder" },
            "toHolder": { "type": "string", "description": "receiving custodian DID (cosign_did)" },
            "toHolderRole": { "type": "string" },
            "referenceOrd": { "type": "string", "description": "reference (e.g. ORD/TRD) this move is linked to; MANDATORY for the attestation-authority mode" },
            "transferredAt": { "type": "integer", "format": "int64", "description": "client-supplied unix-ms; part of the signed canonical bytes (eventHash for the human mode, POD-ATTEST message for the attestation mode)" },
            "fromKeyId": { "type": "string", "description": "human mode: releasing custodian's registered key_id (bound to fromHolder)" },
            "fromSignature": { "type": "string", "description": "human mode: base64-std Ed25519 by fromHolder over the transfer eventHash hex" },
            "toKeyId": { "type": "string", "description": "human mode: receiving custodian's registered key_id (bound to toHolder)" },
            "toSignature": { "type": "string", "description": "human mode: base64-std Ed25519 by toHolder over the SAME eventHash hex" },
            "attestationSignature": { "type": "string", "description": "attestation mode (C3-F2e): base64-std Ed25519 by the configured attestation authority over the POD-ATTEST message; presence selects the single-signature reference-linked path" }
          }
        } } } },
        "responses": {
          "200": { "description": "transferred" },
          "409": { "description": "state/sequence conflict" },
          "422": { "description": "transfer signature rejected (unsigned, invalid, wrong-party, tampered, or unregistered key)" }
        }
      }
    },
    "/v1/custody/passports/{ppid}/split": {
      "post": {
        "operationId": "SplitCustody",
        "summary": "Split into N children (conservation enforced; parent terminal SPLIT). Idempotency-Key required.",
        "parameters": [
          { "name": "ppid", "in": "path", "required": true, "schema": { "type": "string" } },
          { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } }
        ],
        "responses": { "200": { "description": "parent + children" }, "409": { "description": "conservation/state violation" } }
      }
    },
    "/v1/custody/merges": {
      "post": {
        "operationId": "MergeCustody",
        "summary": "Merge same-GPID ACTIVE lots into one new PPID (sources terminal MERGED). Idempotency-Key required.",
        "parameters": [ { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } } ],
        "responses": { "200": { "description": "merged + sources" }, "409": { "description": "violation" } }
      }
    },
    "/v1/custody/recalls": {
      "post": {
        "operationId": "RecallProduct",
        "summary": "Batch regulatory recall of all ACTIVE passports of a GPID (recallId-keyed, no previousHash). Idempotency-Key required.",
        "parameters": [ { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } } ],
        "responses": { "200": { "description": "{recallId, recalled}" }, "404": { "description": "no active passports" } }
      }
    },
    "/v1/custody/passports/{ppid}/sign": {
      "post": {
        "operationId": "SignCustodial",
        "summary": "Append a REAL dual Ed25519 co-signature fact (agent + distinct co-signer, R4/BR-005 four-eyes; status stays ACTIVE). Both signatures sign the eventHash over {ppid,agentDid,signingMode,signedAt,previousHash,coSignerDid}. Idempotency-Key required.",
        "parameters": [
          { "name": "ppid", "in": "path", "required": true, "schema": { "type": "string" } },
          { "name": "Idempotency-Key", "in": "header", "required": true, "schema": { "type": "string" } }
        ],
        "requestBody": { "required": true, "content": { "application/json": { "schema": {
          "type": "object",
          "required": ["agentDid","keyId","signature","coSignerDid","coKeyId","coSignature","signedAt"],
          "properties": {
            "agentDid": { "type": "string" },
            "keyId": { "type": "string" },
            "signature": { "type": "string", "description": "base64-std Ed25519 over eventHash hex" },
            "coSignerDid": { "type": "string" },
            "coKeyId": { "type": "string" },
            "coSignature": { "type": "string", "description": "base64-std Ed25519 over the SAME eventHash hex" },
            "signedAt": { "type": "integer", "format": "int64" }
          }
        } } } },
        "responses": {
          "200": { "description": "signed" },
          "409": { "description": "state violation" },
          "422": { "description": "co-signature rejected (bad/unbound key, four-eyes, or signature does not verify)" }
        }
      }
    },
    "/v1/custody/signer-keys": {
      "post": {
        "operationId": "RegisterSignerKey",
        "summary": "Register a signer's PUBLIC Ed25519 key bound to a DID (C3-F2c verify-side registry; Identity-PKI-fed in prod, FR-PASS-070). CA-GATED root of trust: the binding is accepted ONLY with a valid trust-anchor (CA) Ed25519 signature over the canonical bytes keyId + LF + publicKey + LF + did. Fails CLOSED if the trust anchor is unconfigured. Upsert — no Idempotency-Key required.",
        "requestBody": { "required": true, "content": { "application/json": { "schema": {
          "type": "object",
          "required": ["keyId","publicKey","did","caSignature"],
          "properties": {
            "keyId": { "type": "string" },
            "publicKey": { "type": "string", "description": "base64-std 32-byte Ed25519 public key" },
            "did": { "type": "string" },
            "caSignature": { "type": "string", "description": "base64-std Ed25519 CA signature over keyId + LF + publicKey + LF + did" }
          }
        } } } },
        "responses": {
          "201": { "description": "registered" },
          "400": { "description": "invalid key/did" },
          "422": { "description": "CA signature missing/invalid — binding rejected" },
          "503": { "description": "trust anchor unconfigured — registration closed (fail-closed)" }
        }
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
