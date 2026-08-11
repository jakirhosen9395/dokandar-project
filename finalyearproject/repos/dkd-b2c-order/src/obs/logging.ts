// Structured JSON logging (stdout). B2C-09/EF-OBS-2: every line carries service/context/version
// (and trace_id/span_id when the caller passes them from the request traceparent).
export type Fields = Record<string, unknown>;

const SERVICE = process.env["DKD_SERVICE_NAME"] ?? "b2c-order-svc";
const CONTEXT = "commerce";
const VERSION = process.env["DKD_VERSION"] ?? "0.0.0-dev";

export class Logger {
  info(msg: string, f: Fields = {}): void { this.emit("info", msg, f); }
  error(msg: string, f: Fields = {}): void { this.emit("error", msg, f); }
  private emit(level: string, msg: string, f: Fields): void {
    process.stdout.write(JSON.stringify({
      ts: Date.now(), level, msg,
      service: SERVICE, context: CONTEXT, version: VERSION, // EF-OBS-2 mandatory fields
      ...f,
    }) + "\n");
  }
}

// EF-OBS-2: parse trace_id/span_id from a W3C traceparent header (00-<trace>-<span>-<flags>).
export function traceFields(traceparent: string | undefined): Fields {
  if (!traceparent) return {};
  const parts = traceparent.split("-");
  if (parts.length < 4) return {};
  return { trace_id: parts[1], span_id: parts[2] };
}
