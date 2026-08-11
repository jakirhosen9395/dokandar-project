import { test } from "node:test";
import assert from "node:assert/strict";
import type { IncomingMessage, ServerResponse } from "node:http";
import { Metrics } from "../src/obs/metrics.js";
import { Jwt, hasRole } from "../src/security/jwt.js";
import { handleDocs } from "../src/http/docs.js";

// API Documentation Standard: Swagger UI /docs + OpenAPI JSON /swagger/v1/swagger.json + Bearer.
test("apidocs serves /docs and /swagger/v1/swagger.json with a Bearer scheme", () => {
  const cap = (url: string): { code: number; body: string } => {
    let body = "";
    const res = { statusCode: 0, setHeader() {}, end(b?: string) { body = b ?? ""; } } as unknown as ServerResponse;
    const handled = handleDocs({ url } as IncomingMessage, res, "test-svc");
    assert.equal(handled, true);
    return { code: (res as unknown as { statusCode: number }).statusCode, body };
  };
  assert.equal(cap("/docs").code, 200);
  const spec = cap("/swagger/v1/swagger.json");
  assert.equal(spec.code, 200);
  const doc = JSON.parse(spec.body);
  assert.equal(doc.info.version, "v1");
  assert.ok(doc.components.securitySchemes.Bearer);
});

test("metrics counter exposes prometheus text", () => {
  const m = new Metrics();
  m.inc("http_requests_total");
  assert.match(m.expose(), /http_requests_total 1/);
});

test("jwt rejects malformed bearer and authorizes roles", () => {
  const j = new Jwt("https://identity.dokandar.local");
  assert.equal(j.parse("Bearer not-a-jwt"), null);
  assert.equal(hasRole({ roles: ["ANALYST"] }, "ANALYST"), true);
  assert.equal(hasRole(null, "ANALYST"), false);
});
