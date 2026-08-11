// MUST be imported FIRST (before any @nestjs/* or other module) so the Elastic
// Node agent can monkey-patch http/express/mongodb/ioredis/etc. for full APM.
import apm = require('elastic-apm-node');

if (!apm.isStarted()) {
  apm.start({
    serviceName: process.env.APM_SERVICE_NAME || process.env.SERVICE_NAME || '06-cart',
    serverUrl: process.env.APM_SERVER_URL || '',
    secretToken: process.env.APM_SECRET_TOKEN || '',
    environment: process.env.APP_ENV || 'dev',
    serviceVersion: process.env.CODE_VERSION || undefined,
    active: !!process.env.APM_SERVER_URL,
    captureBody: 'off',
    captureHeaders: false,
    usePathAsTransactionName: false,
    // NOT ignoring /ready: the Docker HEALTHCHECK probes /ready every ~30s, so recording it as a
    // transaction keeps the service in the APM inventory even when idle (matches the 11 fleet
    // services that already do this). /metrics (Prometheus-scraped) + /health stay excluded.
    transactionIgnoreUrls: ['/metrics', '/health'],
    verifyServerCert: false,
  });

  // Normalize outbound-peer dependency names: the auto-http instrumentation labels an exit
  // span's destination by raw host:port. Rename the known platform peers to friendly service
  // names so the Dependencies tab + service map show 04-catalog / 07-coupon / 18-risk-trust,
  // never IP:port (and no manual wrapper span → no duplicate dependency).
  const PEER_BY_PORT: Record<string, string> = { '10004': '04-catalog', '10007': '07-coupon', '10018': '18-risk-trust' };
  (apm as any).addSpanFilter((payload: any) => {
    try {
      const dest = payload?.context?.destination?.service;
      if (dest && typeof dest.resource === 'string') {
        for (const [port, name] of Object.entries(PEER_BY_PORT)) {
          if (dest.resource.includes(':' + port)) {
            dest.resource = name;
            if (dest.name) dest.name = name;
            const tgt = payload?.context?.service?.target;
            if (tgt) tgt.name = name;
          }
        }
      }
    } catch { /* never break span shipping */ }
    return payload;
  });
}
export default apm;
