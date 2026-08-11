<?php

/**
 * Dev-server router for PHP's built-in server (`php -S`).
 *
 * We run `php -S … server.php` instead of `php artisan serve` so that the
 * only per-request log line is the uvicorn-style line emitted by the
 * AccessLog middleware (matching auth/profile). Laravel's ServeCommand
 * wraps worker stdout with a 2-space indent and prints its own duplicate
 * "<path> … ~ Xms" line per request — this router avoids both.
 *
 * Existing files under public/ are served as-is; everything else routes
 * through public/index.php.
 */
$publicPath = __DIR__ . '/public';
$uri = urldecode(parse_url($_SERVER['REQUEST_URI'] ?? '/', PHP_URL_PATH) ?? '/');

if ($uri !== '/' && file_exists($publicPath . $uri) && ! is_dir($publicPath . $uri)) {
    return false; // let the built-in server serve the static asset
}

$_SERVER['SCRIPT_NAME'] = '/index.php';
$_SERVER['SCRIPT_FILENAME'] = $publicPath . '/index.php';

require $publicPath . '/index.php';
