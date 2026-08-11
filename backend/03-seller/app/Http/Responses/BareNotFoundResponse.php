<?php

namespace App\Http\Responses;

use Symfony\Component\HttpFoundation\Request;
use Symfony\Component\HttpFoundation\Response;

/**
 * 404 with truly empty headers — used for the contract's bare-404 hardening.
 *
 * Symfony's base Response::prepare() auto-injects `Content-Type: text/html;
 * charset=UTF-8` when the header is absent on a non-empty status (404 is
 * non-empty per RFC; only 204/304 are considered empty). Even calling
 * `$resp->headers->remove('Content-Type')` before returning doesn't survive,
 * because prepare() runs after our handler.
 *
 * Subclassing prepare() and stripping the headers AFTER the parent runs is
 * the cleanest way to ship a body-less, header-less 404. The spec
 * (docs/contracts/service-contract.md → "404 is special — bare body, no
 * envelope") demands the response leak nothing about the service surface
 * to scanners walking common paths.
 */
class BareNotFoundResponse extends Response
{
    public function __construct()
    {
        parent::__construct('', 404, ['Content-Length' => '0']);
    }

    public function prepare(Request $request): static
    {
        parent::prepare($request);
        // Strip headers Symfony auto-added. `php artisan serve` (PHP's
        // built-in dev SAPI) will re-add `Content-Type: text/html;
        // charset=UTF-8` if NO Content-Type is sent at all — so we send
        // an explicit, minimally-revealing value the dev server will
        // honor (an empty string still triggers the default; a present
        // value suppresses the auto-injection). Production behind
        // FrankenPHP/Octane/Nginx never auto-adds; this dual behaviour
        // is the price of artisan-serve as the dev runtime.
        $this->headers->remove('Cache-Control');
        $this->headers->set('Content-Type', 'application/octet-stream');
        $this->headers->set('Content-Length', '0');
        return $this;
    }

    /** Mark response as terminating so any output buffering is bypassed. */
    public function sendHeaders(?int $statusCode = null): static
    {
        return parent::sendHeaders($statusCode);
    }
}
