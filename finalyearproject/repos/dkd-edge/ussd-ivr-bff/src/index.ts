// ussd-ivr-bff — DOKANDAR edge #35 (R8 USSD ingress). Stateful Bangla menu → same write APIs as app.
import { createServer, type IncomingMessage, type ServerResponse } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { step, type Deps, type Product, type Session } from "./menu.js";

const PORT = Number(process.env["DKD_HTTP_PORT"] ?? "8080");
const BASE = process.env["DKD_UPSTREAM_BASE"] ?? "http://172.17.0.1";
const GATEWAY = process.env["DKD_GATEWAY_URL"] ?? `${BASE}:8116`; // all writes go through the gateway (parity)
const CATALOG = process.env["DKD_CATALOG_URL"] ?? `${BASE}:8088`;
const IDENTITY = process.env["DKD_IDENTITY_URL"] ?? `${BASE}:8080`;
const BUILD_INFO_PATH = process.env["DKD_BUILD_INFO_PATH"] ?? "/app/build-info.json";

function buildInfo(): Record<string, string> {
  try {
    if (existsSync(BUILD_INFO_PATH)) {
      const parsed: unknown = JSON.parse(readFileSync(BUILD_INFO_PATH, "utf8"));
      if (typeof parsed === "object" && parsed !== null) return parsed as Record<string, string>;
    }
  } catch { /* dev default */ }
  return { version: "0.0.0-dev", gitSha: "unknown", buildTime: "unknown" };
}
const BUILD = buildInfo();

const sessions = new Map<string, Session>();
setInterval(() => { if (sessions.size > 10000) sessions.clear(); }, 300000).unref(); // crude TTL guard

async function httpJson(method: string, url: string, body?: unknown, idem?: string): Promise<{ status: number; body: any }> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), 8000);
  try {
    const headers: Record<string, string> = { "Content-Type": "application/json" };
    if (idem) headers["Idempotency-Key"] = idem;
    const init: RequestInit = { method, headers, signal: controller.signal };
    if (body !== undefined) init.body = JSON.stringify(body);
    const res = await fetch(url, init);
    const json: any = await res.json().catch(() => null);
    return { status: res.status, body: json };
  } catch (e) {
    return { status: 503, body: { error: String(e) } };
  } finally { clearTimeout(timer); }
}

// Real upstream wiring — every WRITE goes through the gateway, exactly like the app path (R8 parity).
const deps: Deps = {
  listProducts: async (): Promise<Product[]> => {
    const r = await httpJson("GET", `${CATALOG}/v1/catalog/products?limit=5`);
    const items: any[] = Array.isArray(r.body?.data) ? r.body.data : (r.body?.data?.items ?? []);
    return items
      .filter((p) => (p.status ?? p.Status) === "PUBLISHED")
      .map((p) => ({ gpid: String(p.gpid ?? p.GPID), seller: String(p.createdBy ?? p.CreatedBy ?? ""),
                     name: String(p.namesBn ?? p.namesEn ?? p.gpid) }));
  },
  resolveBuyer: async (phone: string): Promise<string> => {
    // Idempotent onboarding: register the caller's phone; identity returns/keeps their DID.
    const r = await httpJson("POST", `${IDENTITY}/v1/parties`,
      { phoneNumber: phone, otpToken: "000000", locale: "bn-BD" }, `ussd-reg-${phone}`);
    const did = r.body?.data?.did ?? r.body?.did;
    if (!did) throw new Error(`identity did-resolve failed (${r.status})`);
    return String(did);
  },
  placeOrder: async (buyerDid, sellerDid, gpid, qty): Promise<string> => {
    const r = await httpJson("POST", `${GATEWAY}/v1/b2c/orders`, {
      buyerDid, sellerDid,
      items: [{ gpid, quantity: qty, unitPricePoisha: 1500 }],
      deliveryAddress: { line1: "USSD channel", city: "Dhaka" },
    }, `ussd-ord-${buyerDid}-${Date.now()}`);
    const ord = r.body?.data?.ord ?? r.body?.data?.orderId;
    if (!ord) throw new Error(`order failed (${r.status}: ${JSON.stringify(r.body?.error ?? r.body)})`);
    return String(ord);
  },
  getOrderStatus: async (ord: string): Promise<string | null> => {
    const r = await httpJson("GET", `${GATEWAY}/v1/b2c/orders/${encodeURIComponent(ord)}`);
    if (r.status !== 200) return null;
    return String(r.body?.data?.status ?? "UNKNOWN");
  },
};

function send(res: ServerResponse, status: number, body: unknown, ct = "application/json"): void {
  const raw = JSON.stringify(body);
  res.writeHead(status, { "Content-Type": ct, "Content-Length": Buffer.byteLength(raw) });
  res.end(raw);
}

async function readBody(req: IncomingMessage): Promise<Record<string, unknown>> {
  const chunks: Buffer[] = [];
  let size = 0;
  for await (const c of req) { size += (c as Buffer).length; if (size > 65536) throw new Error("body too large"); chunks.push(c as Buffer); }
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) return {};
  const ct = req.headers["content-type"] ?? "";
  if (ct.includes("application/json")) return JSON.parse(raw) as Record<string, unknown>;
  // telco USSD gateways post application/x-www-form-urlencoded
  const out: Record<string, unknown> = {};
  for (const [k, v] of new URLSearchParams(raw)) out[k] = v;
  return out;
}

async function handle(req: IncomingMessage, res: ServerResponse): Promise<void> {
  const path = new URL(req.url ?? "/", "http://bff").pathname;
  if (req.method === "GET" && (path === "/health" || path === "/live")) { send(res, 200, { status: "ok", service: "ussd-ivr-bff", ...BUILD }); return; }
  if (req.method === "GET" && path === "/ready") { send(res, 200, { success: true, data: { status: "ready" }, error: null }); return; }
  if (req.method === "GET" && path === "/version") { send(res, 200, { success: true, data: { service: "ussd-ivr-bff", ...BUILD }, error: null }); return; }
  if (req.method === "POST" && path === "/ussd") {
    const b = await readBody(req);
    const sessionId = String(b["sessionId"] ?? b["session_id"] ?? "");
    const phone = String(b["phoneNumber"] ?? b["msisdn"] ?? "");
    const text = String(b["text"] ?? "");
    if (!sessionId || !phone) { send(res, 400, { type: "about:blank", status: 400, code: "dokandar.edge.ussd.bad_request", detail: "sessionId and phoneNumber are required" }, "application/problem+json"); return; }
    const reply = await step(sessions, sessionId, phone, text, deps);
    // USSD wire format: "CON <menu>" keeps the session open; "END <text>" terminates.
    const wire = (reply.cont ? "CON " : "END ") + reply.message;
    res.writeHead(200, { "Content-Type": "text/plain; charset=utf-8", "Content-Length": Buffer.byteLength(wire) });
    res.end(wire);
    return;
  }
  send(res, 404, { type: "about:blank", status: 404, code: "dokandar.edge.not_found.route", detail: `no route for ${path}` }, "application/problem+json");
}

const server = createServer((req, res) => {
  handle(req, res).catch((e: unknown) => {
    if (!res.headersSent) send(res, 500, { type: "about:blank", status: 500, code: "dokandar.edge.internal.unexpected", detail: String(e) }, "application/problem+json");
  });
});
server.listen(PORT, "0.0.0.0", () => process.stdout.write(JSON.stringify({ msg: "ussd-ivr-bff started", port: PORT }) + "\n"));
const shutdown = (): void => { server.close(() => process.exit(0)); };
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
