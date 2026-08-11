<?php

namespace App\Http\Middleware;

use App\Support\Metrics;
use Closure;
use Illuminate\Http\Request;

/**
 * RED metrics middleware. Increments http_requests_total and observes
 * http_request_duration_seconds for every request. Keeps cardinality
 * bounded by labelling on the matched route PATTERN (e.g.
 * "/api/v1/shop/{id}"), NOT the actual path with the substituted id.
 */
class HttpMetrics
{
    public function handle(Request $request, Closure $next)
    {
        $t = microtime(true);
        $response = $next($request);

        $route = optional($request->route())->uri() ?: 'unmatched';
        $method = $request->getMethod();
        $status = (string) $response->getStatusCode();

        try {
            $svc = Metrics::svc();
            Metrics::httpRequests()->inc([$svc, $method, '/'.$route, $status]);
            Metrics::httpDuration()->observe(microtime(true) - $t, [$svc, $method, '/'.$route]);
        } catch (\Throwable $e) {
            // Metrics storage outage must never break the request path.
        }
        return $response;
    }
}
