import http from "node:http";
import type { IncomingMessage, ServerResponse } from "node:http";
import { Logger, traceFields } from "../obs/logging.js";
import { Metrics } from "../obs/metrics.js";
import { newCorrelationId, newTraceParent } from "../obs/tracing.js";
import { health, live, ready, json } from "./health.js";
import { Router, writeProblem } from "./router.js";
import type { BuildInfo } from "../buildinfo.js";
// Service-local copy of the SDK apidocs helper (added upstream after the frozen v1.3.0 pin;
// fleet pattern: Go services carry their own openapi.go the same way).
import { handleDocs, isDocsPath, DOCS_CSP } from "./docs.js";

function securityHeaders(res: ServerResponse, path: string): void {
  res.setHeader("X-Content-Type-Options", "nosniff");
  res.setHeader("Referrer-Policy", "no-referrer");
  // API Documentation Standard: relax CSP only for the Swagger UI paths; strict elsewhere.
  if (isDocsPath(path)) {
    res.setHeader("Content-Security-Policy", DOCS_CSP);
  } else {
    res.setHeader("X-Frame-Options", "DENY");
    res.setHeader("Content-Security-Policy", "default-src 'none'");
  }
}

export function createServers(
  port: number, metricsPort: number, log: Logger, metrics: Metrics,
  isReady: () => boolean, serviceName: string, router: Router, buildInfo: BuildInfo,
): { http: http.Server; metrics: http.Server } {
  const app = http.createServer((req: IncomingMessage, res: ServerResponse) => {
    const start = Date.now();
    const cid = (req.headers["x-correlation-id"] as string) || newCorrelationId();
    res.setHeader("X-Correlation-Id", cid);
    if (!req.headers["traceparent"]) req.headers["traceparent"] = newTraceParent();
    securityHeaders(res, req.url ?? "");
    metrics.inc("http_requests_total");
    void (async () => {
      try {
        // API Documentation Standard: Swagger UI /docs + OpenAPI JSON /swagger/v1/swagger.json.
        if (handleDocs(req, res, serviceName)) return;
        const path = (req.url ?? "/").split("?")[0];
        switch (path) {
          case "/health": health(res); return;
          case "/live": live(res); return;
          case "/ready": ready(res, isReady()); return;
          case "/version": json(res, 200, { success: true, data: buildInfo }); return;
        }
        if (await router.dispatch(req, res)) return;
        json(res, 404, { success: false, error: { type: "about:blank", title: "not found", status: 404, code: "dokandar.b2c.http.not_found" } });
      } catch (e) {
        log.error("request failed", { err: String(e), path: req.url });
        writeProblem(res, e);
      } finally {
        const elapsedMs = Date.now() - start;
        // B2C-09 RED: Duration histogram + Errors counter (Rate = http_requests_total).
        metrics.observe("http_request_duration_seconds", elapsedMs / 1000);
        if (res.statusCode >= 500) metrics.inc("http_errors_total");
        log.info("request", {
          method: req.method, path: req.url, status: res.statusCode, correlation_id: cid,
          elapsed_ms: elapsedMs, ...traceFields(req.headers["traceparent"] as string | undefined),
        });
      }
    })();
  });

  const metricsSrv = http.createServer((_req, res) => {
    res.writeHead(200, { "Content-Type": "text/plain; version=0.0.4" });
    res.end(metrics.expose());
  });

  app.listen(port);
  metricsSrv.listen(metricsPort);
  return { http: app, metrics: metricsSrv };
}
