<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Illuminate\Support\Str;

/**
 * Echoes the inbound X-Request-Id (or generates a 32-char one) and
 * sets it on the request + response. Used by all subsequent middleware
 * + every log line for correlation.
 */
class RequestId
{
    public function handle(Request $request, Closure $next)
    {
        $rid = $request->header('X-Request-Id');
        if (empty($rid)) {
            $rid = str_replace('-', '', (string) Str::uuid());
        }
        $request->headers->set('X-Request-Id', $rid);
        $response = $next($request);
        if (method_exists($response, 'header')) {
            $response->header('X-Request-Id', $rid);
        } else {
            $response->headers->set('X-Request-Id', $rid);
        }
        return $response;
    }
}
