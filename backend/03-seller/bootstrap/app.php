<?php

use App\Http\Responses\BareNotFoundResponse;
use App\Support\Json;
use Illuminate\Foundation\Application;
use Illuminate\Foundation\Configuration\Exceptions;
use Illuminate\Foundation\Configuration\Middleware;
use Illuminate\Http\Request;
use Symfony\Component\HttpKernel\Exception\HttpExceptionInterface;
use Symfony\Component\HttpKernel\Exception\MethodNotAllowedHttpException;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

return tap(Application::configure(basePath: dirname(__DIR__))
    ->withRouting(
        // Shop is an API-only service. Using `api:` (instead of `web:`)
        // puts routes through Laravel's API middleware stack — NO session,
        // CSRF, cookie encryption. `apiPrefix: ''` mounts routes at root
        // so our /ready /health /api/v1/shop/* paths stay flat.
        api: __DIR__.'/../routes/api.php',
        apiPrefix: '',
        commands: __DIR__.'/../routes/console.php',
    )
    ->withMiddleware(function (Middleware $middleware) {
        // Order matters — outermost first when prepended in reverse below.
        // Final order:
        //   1. RequestId        (every log/metric has X-Request-Id)
        //   2. HttpMetrics      (observes final response code + duration)
        //   3. AccessLog        (emits the per-request log line for ES sink)
        $middleware->prepend(\App\Http\Middleware\AccessLog::class);
        $middleware->prepend(\App\Http\Middleware\HttpMetrics::class);
        $middleware->prepend(\App\Http\Middleware\RequestId::class);
    })
    ->withExceptions(function (Exceptions $exceptions) {
        // BARE 404 — unmapped paths return HTTP 404 with content-length 0,
        // an empty body, AND a stripped Content-Type header. Symfony's
        // Response constructor would default Content-Type to text/html;
        // we explicitly remove it so a scanner/probe learns nothing about
        // the service surface (the spec calls this out as info-hiding).
        $exceptions->render(function (NotFoundHttpException $e, Request $r) {
            // BareNotFoundResponse overrides prepare() to strip Content-Type
            // AFTER Symfony tries to re-add it. The default Response path
            // would otherwise leak `Content-Type: text/html` to scanners.
            return new BareNotFoundResponse();
        });
        $exceptions->render(function (MethodNotAllowedHttpException $e, Request $r) {
            return Json::error(405, 'method_not_allowed', 'Method Not Allowed',
                (string) $r->header('X-Request-Id', ''));
        });
        $exceptions->render(function (HttpExceptionInterface $e, Request $r) {
            $code = match ($e->getStatusCode()) {
                400 => 'bad_request', 401 => 'unauthorized', 403 => 'forbidden',
                409 => 'conflict', 413 => 'payload_too_large', 415 => 'unsupported_media_type',
                422 => 'validation_error', 429 => 'rate_limited', 500 => 'internal_error',
                502 => 'bad_gateway', 503 => 'service_unavailable', 504 => 'gateway_timeout',
                default => 'http_error',
            };
            return Json::error(
                $e->getStatusCode(),
                $code,
                $e->getMessage() ?: ucwords(str_replace('_', ' ', $code)),
                (string) $r->header('X-Request-Id', '')
            );
        });
        // Final safety net: any uncaught \Throwable in a route maps to a
        // 500 internal_error envelope rather than the framework's default
        // HTML page. Without this, a transient DB error on /shop/shops
        // would leak the Laravel stack trace.
        $exceptions->render(function (\Throwable $e, Request $r) {
            if ($e instanceof HttpExceptionInterface) return null;
            return Json::error(500, 'internal_error',
                config('app.debug') ? $e->getMessage() : 'Internal server error.',
                (string) $r->header('X-Request-Id', ''));
        });
    })
    ->create(), function ($app) {
        // Skip Laravel's default phpdotenv-based env loader. Config is
        // injected via docker --env-file at runtime; the file-read path
        // produces APM-noise errors. See SkipEnvLoader for the full why.
        $app->bind(
            \Illuminate\Foundation\Bootstrap\LoadEnvironmentVariables::class,
            \App\Http\Bootstrap\SkipEnvLoader::class
        );
    });
