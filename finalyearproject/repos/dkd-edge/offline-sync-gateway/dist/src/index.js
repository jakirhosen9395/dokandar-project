// offline-sync-gateway — DOKANDAR edge. Store-and-forward replay of a device's queued offline writes.
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { replayBatch } from "./sync.js";
const PORT = Number(process.env["DKD_HTTP_PORT"] ?? "8080");
const BASE = process.env["DKD_UPSTREAM_BASE"] ?? "http://172.17.0.1";
const GATEWAY = process.env["DKD_GATEWAY_URL"] ?? `${BASE}:8116`; // replay onto the public gateway (parity)
const BUILD_INFO_PATH = process.env["DKD_BUILD_INFO_PATH"] ?? "/app/build-info.json";
const MAX_OPS = 50;
function buildInfo() {
    try {
        if (existsSync(BUILD_INFO_PATH)) {
            const p = JSON.parse(readFileSync(BUILD_INFO_PATH, "utf8"));
            if (typeof p === "object" && p !== null)
                return p;
        }
    }
    catch { /* dev */ }
    return { version: "0.1.0", gitSha: "unknown", buildTime: "unknown" };
}
const BUILD = buildInfo();
const forward = async (op) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
        const init = { method: op.method, headers: { "Content-Type": "application/json", "Idempotency-Key": op.idempotencyKey }, signal: controller.signal };
        if (op.body !== undefined)
            init.body = JSON.stringify(op.body);
        const res = await fetch(GATEWAY + op.path, init);
        const body = await res.json().catch(() => null);
        return { status: res.status, body };
    }
    finally {
        clearTimeout(timer);
    }
};
function send(res, status, body, ct = "application/json") {
    const raw = JSON.stringify(body);
    res.writeHead(status, { "Content-Type": ct, "Content-Length": Buffer.byteLength(raw) });
    res.end(raw);
}
function problem(res, status, code, detail) {
    send(res, status, { type: "about:blank", status, code, detail }, "application/problem+json");
}
async function readJson(req) {
    const chunks = [];
    let size = 0;
    for await (const c of req) {
        size += c.length;
        if (size > 1_048_576)
            throw new Error("batch too large");
        chunks.push(c);
    }
    const raw = Buffer.concat(chunks).toString("utf8").trim();
    return raw ? JSON.parse(raw) : {};
}
async function handle(req, res) {
    const path = new URL(req.url ?? "/", "http://sync").pathname;
    if (req.method === "GET" && (path === "/health" || path === "/live")) {
        send(res, 200, { success: true, data: { status: "ok", service: "offline-sync-gateway", ...BUILD }, error: null });
        return;
    }
    if (req.method === "GET" && path === "/ready") {
        send(res, 200, { success: true, data: { status: "ready" }, error: null });
        return;
    }
    if (req.method === "GET" && path === "/version") {
        send(res, 200, { success: true, data: { service: "offline-sync-gateway", ...BUILD }, error: null });
        return;
    }
    if (req.method === "POST" && path === "/v1/sync/batch") {
        const b = await readJson(req);
        const ops = b["ops"];
        if (!Array.isArray(ops)) {
            problem(res, 400, "dokandar.edge.sync.bad_batch", "body must be { ops: [...] }");
            return;
        }
        if (ops.length === 0 || ops.length > MAX_OPS) {
            problem(res, 422, "dokandar.edge.sync.batch_size", `a batch must carry 1..${MAX_OPS} ops`);
            return;
        }
        const results = await replayBatch(ops, forward);
        const applied = results.filter((r) => r.ok).length;
        send(res, 200, { success: true, data: { applied, total: results.length, results }, error: null, meta: { asOf: Date.now() } });
        return;
    }
    problem(res, 404, "dokandar.edge.not_found.route", `no route for ${path}`);
}
const server = createServer((req, res) => { handle(req, res).catch((e) => { if (!res.headersSent)
    problem(res, 500, "dokandar.edge.internal.unexpected", String(e)); }); });
server.listen(PORT, "0.0.0.0", () => process.stdout.write(JSON.stringify({ msg: "offline-sync-gateway started", port: PORT }) + "\n"));
const shutdown = () => { server.close(() => process.exit(0)); };
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
