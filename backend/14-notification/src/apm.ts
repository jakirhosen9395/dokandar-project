// MUST be imported FIRST (before any other module) so the Elastic Node agent
// can monkey-patch http/mongodb/ioredis/kafkajs/amqplib/etc. for full APM.
import apm = require('elastic-apm-node');

if (!apm.isStarted()) {
  apm.start({
    serviceName: process.env.APM_SERVICE_NAME || process.env.SERVICE_NAME || '14-notification',
    serverUrl: process.env.APM_SERVER_URL || '',
    secretToken: process.env.APM_SECRET_TOKEN || '',
    environment: process.env.APP_ENV || 'dev',
    serviceVersion: process.env.CODE_VERSION || undefined,
    active: !!process.env.APM_SERVER_URL,
    captureBody: 'off',
    captureHeaders: false,
    usePathAsTransactionName: false,
    // NOT ignoring /ready: the Docker HEALTHCHECK probes /ready every ~30s, so recording it as a
    // transaction keeps this consumer service in the APM inventory even when no events flow (matches
    // the 11 fleet services that already do this). /metrics (Prometheus) + /health stay excluded.
    transactionIgnoreUrls: ['/metrics', '/health'],
    verifyServerCert: false,
  });

  // Keep the Errors tab actionable: AppError is the service's BUSINESS error envelope (401 unauthorized,
  // 404 not_found, 422 invalid_request, 409 conflict). Those are expected transaction OUTCOMES, not
  // defects, but the agent auto-captures every error reaching Fastify's setErrorHandler. Drop AppError
  // from error capture (real internal errors are NOT AppError, so they still surface).
  (apm as any).addErrorFilter((payload: any) => {
    try {
      const t = payload?.exception?.type || payload?.error?.exception?.[0]?.type;
      if (t === 'AppError') return false; // drop expected business error
    } catch { /* never break error shipping */ }
    return payload;
  });
}
export default apm;
