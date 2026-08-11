import type { ServerResponse } from "node:http";
import { CONTRACT_VERSION, GENERATOR_VERSION } from "@dokandar/platform-sdk";

export function json(res: ServerResponse, status: number, body: unknown): void {
  res.writeHead(status, { "Content-Type": "application/json" });
  res.end(JSON.stringify(body));
}

export function health(res: ServerResponse): void {
  json(res, 200, { success: true, data: { status: "ok" } });
}
export function live(res: ServerResponse): void {
  json(res, 200, { success: true, data: { status: "alive" } });
}
export function ready(res: ServerResponse, isReady: boolean): void {
  if (!isReady) { json(res, 503, { success: false, data: { status: "not-ready" } }); return; }
  json(res, 200, { success: true, data: { status: "ready" } });
}
export function version(res: ServerResponse): void {
  json(res, 200, { success: true, data: { contractVersion: CONTRACT_VERSION, sdkGenerator: GENERATOR_VERSION } });
}
