<?php

namespace App\Support;

/**
 * Persistent process-boot timestamp.
 *
 * Why this exists: under `php artisan serve` each HTTP request runs in a
 * fresh PHP process, so `microtime(true)` captured at routes-file load
 * resets every request and `uptime_seconds` always reports 0.
 *
 * The entrypoint writes `/tmp/dokandar-seller.boot` once at container start
 * with the epoch seconds; this class reads the mtime on every request and
 * caches it in static memory for the lifetime of the current request.
 * Falls back to the file's mtime, then to `now()` if neither exists (so
 * uptime can never be negative or unbounded).
 */
class BootTime
{
    private const STAMP_FILE = '/tmp/dokandar-seller.boot';
    private static ?float $cached = null;

    public static function epoch(): float
    {
        if (self::$cached !== null) {
            return self::$cached;
        }
        if (is_file(self::STAMP_FILE)) {
            $raw = trim((string) @file_get_contents(self::STAMP_FILE));
            if ($raw !== '' && is_numeric($raw)) {
                self::$cached = (float) $raw;
                return self::$cached;
            }
            $mtime = @filemtime(self::STAMP_FILE);
            if ($mtime !== false) {
                self::$cached = (float) $mtime;
                return self::$cached;
            }
        }
        self::$cached = microtime(true);
        return self::$cached;
    }

    public static function uptimeSeconds(): int
    {
        $u = (int) (microtime(true) - self::epoch());
        return max(0, $u);
    }

    /** Reset the in-process cache — only for tests. */
    public static function reset(): void
    {
        self::$cached = null;
    }
}
