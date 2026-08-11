<?php

namespace App\Support;

use Prometheus\CollectorRegistry;
use Prometheus\Counter;
use Prometheus\Gauge;
use Prometheus\Histogram;
use Prometheus\RenderTextFormat;
use Prometheus\Storage\Redis as RedisStore;

/**
 * Thin singleton over the prometheus_client_php registry. Uses a Redis
 * backend (so metric state survives a request boundary in PHP — Laravel
 * is request-per-process under `artisan serve`).
 *
 * Four metrics matter for this build:
 *   - http_requests_total{service,method,route,status}    counter (RED rate + errors)
 *   - http_request_duration_seconds{service,method,route} histogram (RED latency)
 *   - seller_shops_created_total{service}                 counter (business)
 *   - seller_shops_activated_total{service}               counter (business)
 *   - seller_geo_searches_total{service}                  counter (business)
 *   - seller_outbox_pending{service}                      gauge   (recomputed on scrape)
 *
 * §16-b: metric NAME prefix is `seller_` (NOT `shop_`); every series carries
 * a `service="03-seller"` label (Metrics::svc()).
 */
class Metrics
{
    private static ?CollectorRegistry $registry = null;
    /**
     * Per-request cache of already-registered metric objects.
     *
     * WHY: prometheus_client_php's getOrRegister*() does `try { getX() } catch
     * (MetricNotFoundException) { registerX() }`. On a fresh registry (rebuilt
     * every request — PHP resets userland statics under `php -S`/artisan serve)
     * the getX() ALWAYS throws MetricNotFoundException on first use, then
     * catches it. The throw is harmless (we still register + metrics work), but
     * the Elastic APM PHP agent records thrown exceptions at the zend layer even
     * when caught, so this benign exception floods the APM Errors tab once per
     * request. We avoid it entirely by calling the NON-throwing registerX() once
     * per request and caching the object — getX() (and its exception) is never
     * invoked. registerX() does not throw on a fresh registry; the cache guard
     * also covers the case where statics DO persist (then registerX isn't called
     * a second time). See [[elastic-apm-php-suppressed-errors]].
     *
     * @var array<string,mixed>
     */
    private static array $metrics = [];

    /** The service-identity label value carried by every series (§16-b). */
    public static function svc(): string
    {
        return (string) (config('shop.identity.service_name') ?: '03-seller');
    }

    public static function registry(): CollectorRegistry
    {
        if (self::$registry !== null) {
            return self::$registry;
        }
        $store = new RedisStore([
            'host' => env('REDIS_HOST', '127.0.0.1'),
            'port' => (int) env('REDIS_PORT', 6379),
            'password' => env('REDIS_PASSWORD') ?: null,
            'database' => (int) env('REDIS_METRICS_DB', 3),     // separate db from cache (db=2)
            'timeout' => 1.0,
            'read_timeout' => 5.0,
        ]);
        self::$registry = new CollectorRegistry($store, false);
        return self::$registry;
    }

    public static function httpRequests(): Counter
    {
        return self::$metrics['http_requests_total'] ??= self::registry()->registerCounter(
            'http', 'requests_total',
            'HTTP requests served, by method + route + status.',
            ['service', 'method', 'route', 'status']
        );
    }

    public static function httpDuration(): Histogram
    {
        return self::$metrics['http_request_duration_seconds'] ??= self::registry()->registerHistogram(
            'http', 'request_duration_seconds',
            'HTTP request duration histogram.',
            ['service', 'method', 'route'],
            [0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10]
        );
    }

    public static function shopsCreated(): Counter
    {
        return self::$metrics['shops_created_total'] ??= self::registry()->registerCounter(
            'seller', 'shops_created_total',
            'Shops created via POST /api/v1/shop/shops.',
            ['service']
        );
    }

    public static function shopsActivated(): Counter
    {
        return self::$metrics['shops_activated_total'] ??= self::registry()->registerCounter(
            'seller', 'shops_activated_total',
            'Successful POST /api/v1/shop/{id}/activate calls.',
            ['service']
        );
    }

    public static function geoSearches(): Counter
    {
        return self::$metrics['geo_searches_total'] ??= self::registry()->registerCounter(
            'seller', 'geo_searches_total',
            'GET /api/v1/shop/shops/near requests.',
            ['service']
        );
    }

    public static function outboxPending(): Gauge
    {
        return self::$metrics['outbox_pending'] ??= self::registry()->registerGauge(
            'seller', 'outbox_pending',
            'Outbox rows with sent_at IS NULL (Kafka relay lag indicator).',
            ['service']
        );
    }

    /** Render the registry as Prometheus text. */
    public static function render(): string
    {
        $renderer = new RenderTextFormat();
        return $renderer->render(self::registry()->getMetricFamilySamples());
    }
}
