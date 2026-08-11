import { Registry, Counter, Histogram, Gauge, collectDefaultMetrics } from 'prom-client';
export const registry = new Registry();
export const SERVICE_VAL = '06-cart';
collectDefaultMetrics({ register: registry, prefix: 'cart_' });
export const httpRequests = new Counter({ name: 'http_requests_total', help: 'HTTP requests by method/route/status', labelNames: ['method', 'route', 'status'], registers: [registry] });
export const httpDuration = new Histogram({ name: 'http_request_duration_seconds', help: 'HTTP latency', labelNames: ['method', 'route'], registers: [registry] });
export const cartItemMutations = new Counter({ name: 'cart_item_mutations_total', help: 'cart item mutations', labelNames: ['service', 'op'], registers: [registry] });
export const cartCheckoutTotal = new Counter({ name: 'cart_checkout_package_total', help: 'checkout-package outcomes', labelNames: ['service', 'outcome'], registers: [registry] });
export const cartGrpcCalls = new Counter({ name: 'cart_grpc_calls_total', help: 'downstream calls', labelNames: ['service', 'peer', 'result'], registers: [registry] });
export const cartIdemHits = new Counter({ name: 'cart_idempotency_hits_total', help: 'idempotency replays', labelNames: ['service'], registers: [registry] });
export const cartCheckoutBuildMs = new Histogram({ name: 'cart_checkout_build_ms', help: 'checkout-package build latency (ms)', labelNames: ['service'], registers: [registry] });
export const cartActiveUsers = new Gauge({ name: 'cart_active_users', help: 'carts with >=1 item', labelNames: ['service'], registers: [registry] });
export function observe(method: string, route: string, status: number, secs: number): void {
  httpRequests.inc({ method, route, status: String(status) });
  httpDuration.observe({ method, route }, secs);
}
export function render(): Promise<string> { return registry.metrics(); }
