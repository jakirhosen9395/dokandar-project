import { randomBytes } from "node:crypto";
// W3C traceparent propagation. The OpenTelemetry SDK is the export integration point.
export function newTraceParent(): string {
  return `00-${randomBytes(16).toString("hex")}-${randomBytes(8).toString("hex")}-01`;
}
export function newCorrelationId(): string { return randomBytes(16).toString("hex"); }
