import { ArgumentsHost, Catch, ExceptionFilter, HttpException } from '@nestjs/common';
import apm from './apm';
import { logger } from './observability/logger';

const CODES: Record<number, string> = { 400: 'bad_request', 401: 'unauthorized', 403: 'forbidden', 404: 'not_found', 405: 'method_not_allowed', 409: 'conflict', 422: 'invalid_request', 429: 'rate_limited', 500: 'internal_error', 503: 'dependency_unavailable' };

@Catch()
export class EnvelopeFilter implements ExceptionFilter {
  catch(exception: any, host: ArgumentsHost) {
    const ctx = host.switchToHttp(); const res = ctx.getResponse(); const req = ctx.getRequest();
    const rid = req?.headers?.['x-request-id'] || '';
    if (exception instanceof HttpException) {
      const status = exception.getStatus(); const body: any = exception.getResponse();
      if (typeof body === 'object' && body && body.error && typeof body.error === 'object') { body.error.request_id = rid; return res.status(status).type('application/json').send(JSON.stringify(body, null, 2) + '\n'); }
      if (status === 404) {
        // Bound APM cardinality: name unmatched 404s "<METHOD> unmatched" (not "unknown route").
        const tx: any = apm.currentTransaction; if (tx) tx.name = (req?.method || 'GET') + ' unmatched';
        return res.status(404).end();
      }
      const code = CODES[status] || 'error';
      const msg = typeof body === 'string' ? body : body?.message || code;
      return res.status(status).type('application/json').send(JSON.stringify({ error: { code, message: msg, request_id: rid } }, null, 2) + '\n');
    }
    // This @Catch() filter swallows the exception, so the agent's auto-capture never sees it —
    // capture it explicitly so unhandled errors appear in the APM Errors tab with the trace.
    try { apm.captureError(exception); } catch { /* apm off */ }
    logger.error('cart.error', `unhandled: ${exception?.message || exception}`);
    res.status(500).type('application/json').send(JSON.stringify({ error: { code: 'internal_error', message: 'internal error', request_id: rid } }, null, 2) + '\n');
  }
}
