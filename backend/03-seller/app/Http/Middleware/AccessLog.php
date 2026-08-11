<?php

namespace App\Http\Middleware;

use Closure;
use Illuminate\Http\Request;
use Symfony\Component\HttpFoundation\Response as SymfonyResponse;

/**
 * Emit one uvicorn-style access line per HTTP request straight to stdout,
 * matching the auth (Python/uvicorn) + profile (Go) services:
 *
 *   INFO:     103.197.153.50:44648 - "GET /health HTTP/1.1" 200 OK
 *
 * This is deliberately NOT routed through Monolog — the canonical JSON
 * channels carry application events; access lines are plain text on stdout
 * (and stay out of the Mongo/ES sinks, which APM transaction docs cover).
 * `/ready`, `/metrics` AND `/health` are silenced (load-balancer / scrape
 * probe noise — architecture.md §10.2 / §16-g).
 */
class AccessLog
{
    public function handle(Request $request, Closure $next)
    {
        $response = $next($request);

        try {
            $path = '/' . ltrim($request->path(), '/');
            if ($path === '/ready' || $path === '/metrics' || $path === '/health') {
                return $response;
            }

            $ip   = $request->ip() ?: '-';
            $port = (string) $request->server('REMOTE_PORT', '');
            $remote = $port !== '' ? "{$ip}:{$port}" : $ip;

            $method = $request->getMethod();
            $proto  = (string) $request->server('SERVER_PROTOCOL', 'HTTP/1.1');
            $status = $response->getStatusCode();
            $reason = SymfonyResponse::$statusTexts[$status] ?? '';

            $timestamp = (new \DateTime('now', new \DateTimeZone('UTC')))->format('d-m-Y H:i:s');
            $line = sprintf(
                "%s    %s - \"%s %s %s\" %d %s\n",
                $timestamp, $remote, $method, $path, $proto, $status, $reason
            );
            @file_put_contents('php://stdout', $line);
        } catch (\Throwable $e) {
            // Logging must never break a request.
        }

        return $response;
    }
}
