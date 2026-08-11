// app-bff — DOKANDAR edge #34. Stateless HTTP; no store, no spine, no business writes.
import { createServer } from "node:http";
import { readFileSync, existsSync } from "node:fs";
import { composeOrderView } from "./view.js";
const PORT = Number(process.env["DKD_HTTP_PORT"] ?? "8080");
const BASE = process.env["DKD_UPSTREAM_BASE"] ?? "http://172.17.0.1";
const UP = {
    b2c: process.env["DKD_B2C_URL"] ?? `${BASE}:8102`,
    logistics: process.env["DKD_LOGISTICS_URL"] ?? `${BASE}:8104`,
    finance: process.env["DKD_FINANCE_URL"] ?? `${BASE}:8100`,
    notification: process.env["DKD_NOTIFICATION_URL"] ?? `${BASE}:8114`,
};
const BUILD_INFO_PATH = process.env["DKD_BUILD_INFO_PATH"] ?? "/app/build-info.json";
// read ONCE at startup — never a blocking syscall inside a live request (reviewer H-2)
function buildInfo() {
    try {
        if (existsSync(BUILD_INFO_PATH)) {
            const parsed = JSON.parse(readFileSync(BUILD_INFO_PATH, "utf8"));
            if (typeof parsed === "object" && parsed !== null) {
                return parsed;
            }
        }
    }
    catch {
        // fall through to dev defaults
    }
    return { version: "0.0.0-dev", gitSha: "unknown", buildTime: "unknown" };
}
const MAX_UPSTREAM_BYTES = 1_048_576; // 1MB cap — never buffer an unbounded body
const BUILD = buildInfo();
const fetcher = async (url) => {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), 8000);
    try {
        const res = await fetch(url, { signal: controller.signal });
        const cl = Number(res.headers.get("content-length") ?? 0);
        if (cl > MAX_UPSTREAM_BYTES)
            return { status: 503, body: null };
        const body = await res.json().catch(() => null);
        return { status: res.status, body };
    }
    catch {
        return { status: 503, body: null };
    }
    finally {
        clearTimeout(timer);
    }
};
function json(res, status, body, ct = "application/json") {
    const raw = JSON.stringify(body);
    res.writeHead(status, { "Content-Type": ct, "Content-Length": Buffer.byteLength(raw) });
    res.end(raw);
}
function problem(res, status, code, detail) {
    json(res, status, {
        type: "about:blank", title: code.split(".").pop(), status, code, detail,
    }, "application/problem+json");
}
async function handle(req, res) {
    const url = new URL(req.url ?? "/", "http://bff");
    const path = url.pathname;
    if (req.method !== "GET") {
        problem(res, 405, "dokandar.edge.request.method", "the app-bff serves aggregate READS only");
        return;
    }
    if (path === "/health" || path === "/live") {
        json(res, 200, { status: "ok", service: "app-bff", ...BUILD });
        return;
    }
    if (path === "/ready") {
        json(res, 200, { success: true, data: { status: "ready" }, error: null });
        return;
    }
    if (path === "/version") {
        json(res, 200, { success: true, data: BUILD, error: null });
        return;
    }
    const orderView = /^\/v1\/app\/orders\/([^/]+)\/view$/.exec(path);
    if (orderView !== null) {
        const ord = decodeURIComponent(orderView[1] ?? "");
        const { status, view } = await composeOrderView(fetcher, UP, ord);
        if (status !== 200) {
            problem(res, status, String(view["code"] ?? "dokandar.edge.internal.unexpected"), `order view for ${ord} unavailable`);
            return;
        }
        json(res, 200, { success: true, data: view, error: null, meta: { asOf: Date.now() } });
        return;
    }
    problem(res, 404, "dokandar.edge.not_found.route", `no BFF route for ${path}`);
}
const server = createServer((req, res) => {
    const start = Date.now();
    res.on("finish", () => {
        if (req.url !== "/health" && req.url !== "/live" && req.url !== "/ready") {
            process.stdout.write(JSON.stringify({ msg: "request", method: req.method,
                path: req.url, status: res.statusCode, ms: Date.now() - start }) + "\n");
        }
    });
    handle(req, res).catch((e) => {
        if (res.headersSent)
            return; // never double-write a committed response
        problem(res, 500, "dokandar.edge.internal.unexpected", String(e));
    });
});
server.listen(PORT, "0.0.0.0", () => {
    process.stdout.write(JSON.stringify({ msg: "app-bff started", port: PORT }) + "\n");
});
const shutdown = () => { server.close(() => process.exit(0)); };
process.on("SIGINT", shutdown);
process.on("SIGTERM", shutdown);
