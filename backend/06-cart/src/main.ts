import './apm'; // MUST be first — Elastic APM agent monkey-patches before everything else
import 'reflect-metadata';
import { HttpException, ValidationPipe } from '@nestjs/common';
import { NestFactory } from '@nestjs/core';
import { DocumentBuilder, SwaggerModule } from '@nestjs/swagger';
import { randomUUID } from 'crypto';
import { AppModule } from './app.module';
import { EnvelopeFilter } from './common';
import { config } from './config';
import { accessLog, logger, startSinks } from './observability/logger';
import { observe } from './observability/metrics';
import { startConsumers } from './kafka.consumer';

async function bootstrap() {
  startSinks();
  logger.info('cart.boot', `starting ${config.serviceName} code_version=${config.codeVersion} port=${config.servicePort} tenant=${config.tenant} env=${config.appEnv}`);
  const app = await NestFactory.create(AppModule, { logger: false });
  app.getHttpAdapter().getInstance().set('json spaces', 2); // pretty JSON
  app.useGlobalPipes(new ValidationPipe({ transform: true, whitelist: true, exceptionFactory: (errors) => new HttpException({ error: { code: 'invalid_request', message: 'request validation failed', details: errors.map((e) => ({ field: e.property, constraints: e.constraints })) } }, 422) }));
  app.useGlobalFilters(new EnvelopeFilter());

  app.use((req: any, res: any, next: any) => {
    const rid = req.headers['x-request-id'] || randomUUID().replace(/-/g, '');
    req.headers['x-request-id'] = rid; res.setHeader('x-request-id', rid);
    const start = Date.now();
    res.on('finish', () => {
      const route = (req.route && req.baseUrl + req.route.path) || req.path;
      if (req.path !== '/metrics' && req.path !== '/ready') {
        observe(req.method, route, res.statusCode, (Date.now() - start) / 1000);
        accessLog(`${req.socket.remoteAddress}:${req.socket.remotePort}`, req.method, req.originalUrl, res.statusCode, res.statusMessage || '');
      }
    });
    next();
  });

  const docDescription = [
    `**service_name**: \`${config.serviceName}\` | **code_version**: \`${config.codeVersion}\` | **env_version**: \`${config.envVersion}\` | **tenant**: \`${config.tenant}\` | **env**: \`${config.appEnv}\``,
    '',
    '**Cart & Checkout-Package (06-cart).** Authenticated + guest carts, wishlists, and the immutable checkout-package quote that 13-order replays at place time. MongoDB cart store + Redis DB5 (guest carts, Redlock, idempotency). The quote fans out to catalog (fail-closed), coupon (fail-open), risk (fail-closed/COD-hold). Pretty-JSON; errors use the platform `{error:{code,message,request_id,details}}` envelope with lowercase snake_case codes. Money is integer **paisa** (`*_minor`).',
    '',
    '### How to test',
    '1. Click **Authorize** and paste a Bearer **access token** from 01-auth (`POST /api/v1/auth/login/request` → `/login/verify`). Authenticated cart/wishlist/checkout routes need it; guest-cart reads/writes (`/guest/{cookieId}`) do not.',
    '2. Request bodies are pre-filled with working examples. `shop_id`/`product_id`/`variant_id` are opaque UUIDs from 04-catalog.',
    '3. `POST /me/checkout-package` requires a unique **`Idempotency-Key`** header; replaying the same key returns the same quote.',
  ].join('\n');

  const docCfg = new DocumentBuilder()
    .setTitle('DOKANDAR Cart Service')
    .setVersion(config.codeVersion)
    .setDescription(docDescription)
    .setContact('DOKANDAR Platform', 'https://dokandar.com.bd', 'api@dokandar.com.bd')
    .setLicense('Proprietary', '')
    .addServer('https://api.dokandar.com.bd', 'prod')
    .addServer('http://localhost:10006', 'local')
    .addBearerAuth({ type: 'http', scheme: 'bearer', bearerFormat: 'JWT', description: 'RS256 token minted by 01-auth' }, 'HTTPBearer')
    .addTag('cart', 'Cart, wishlist, guest cart, and the checkout-package quote')
    .addTag('ops', 'Operational contract — readiness, health, data, metrics')
    .build();
  const doc = SwaggerModule.createDocument(app, docCfg);
  SwaggerModule.setup('docs', app, doc, { customSiteTitle: '06-cart API', jsonDocumentUrl: 'openapi.json', swaggerOptions: { persistAuthorization: true, tryItOutEnabled: true } });

  try { startConsumers(); } catch (e: any) { logger.warn('cart.boot', `kafka consumers not started: ${e?.message}`); }
  await app.listen(config.servicePort, '0.0.0.0');
  logger.warn('cart.boot', `http server listening on :${config.servicePort}`);
}
bootstrap();
