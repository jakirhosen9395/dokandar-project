import { Registry, Counter, Histogram, Gauge, collectDefaultMetrics } from 'prom-client';
export const registry = new Registry();
export const SERVICE_VAL = '14-notification';
collectDefaultMetrics({ register: registry, prefix: 'notification_' });

// RED — closed-set labels (method, route, status). No service label here (06-cart parity).
export const httpRequests = new Counter({ name: 'http_requests_total', help: 'HTTP requests by method/route/status', labelNames: ['method', 'route', 'status'], registers: [registry] });
export const httpDuration = new Histogram({ name: 'http_request_duration_seconds', help: 'HTTP latency', labelNames: ['method', 'route'], registers: [registry] });

// Notification business metrics — CLOSED-SET labels only (service, channel). NEVER user_id.
// No outbox → NO *_outbox_pending gauge (terminal consumer).
export const notificationSent = new Counter({ name: 'notification_sent_total', help: 'notifications dispatched per channel', labelNames: ['service', 'channel'], registers: [registry] });
export const notificationDedupHits = new Counter({ name: 'notification_dedup_hits_total', help: 'Kafka redeliveries absorbed by the dedup window', labelNames: ['service'], registers: [registry] });
export const notificationWsConnections = new Gauge({ name: 'notification_websocket_connections', help: 'live WebSocket inbox connections', labelNames: ['service'], registers: [registry] });
export const notificationChannelQueueDepth = new Gauge({ name: 'notification_channel_queue_depth', help: 'RabbitMQ channel queue depth per channel', labelNames: ['service', 'channel'], registers: [registry] });

// RED helpers (06-cart parity)
export function observe(method: string, route: string, status: number, secs: number): void {
  httpRequests.inc({ method, route, status: String(status) });
  httpDuration.observe({ method, route }, secs);
}
export function render(): Promise<string> { return registry.metrics(); }

// Notification business helpers — service label baked from SERVICE_VAL
export function incSent(channel: string): void { notificationSent.inc({ service: SERVICE_VAL, channel }); }
export function incDedup(): void { notificationDedupHits.inc({ service: SERVICE_VAL }); }
export function setWsConnections(n: number): void { notificationWsConnections.set({ service: SERVICE_VAL }, n); }
export function wsConnInc(): void { notificationWsConnections.inc({ service: SERVICE_VAL }); }
export function wsConnDec(): void { notificationWsConnections.dec({ service: SERVICE_VAL }); }
export function setChannelQueueDepth(channel: string, n: number): void { notificationChannelQueueDepth.set({ service: SERVICE_VAL, channel }, n); }
