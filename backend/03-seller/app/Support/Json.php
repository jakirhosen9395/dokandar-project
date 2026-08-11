<?php

namespace App\Support;

use Illuminate\Http\JsonResponse;
use Symfony\Component\HttpFoundation\Response;

/**
 * Platform-wide pretty-JSON encoder for the Shop service.
 *
 * PHP's JSON_PRETTY_PRINT hard-codes 4-space indent; the platform contract
 * (docs/contracts/service-contract.md → "Pretty JSON") asks for 2 spaces +
 * unescaped slashes + unescaped unicode + trailing newline. We post-process
 * the 4-space output to 2 spaces — safe because we control the data shape
 * (no user-supplied strings ever start with 4 leading spaces) and the
 * substitution only touches the structural indent that PHP itself emits.
 */
class Json
{
    public const FLAGS = JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE | JSON_UNESCAPED_SLASHES;

    /** Encode the given value to the platform pretty-JSON shape. */
    public static function encode(mixed $value): string
    {
        $raw = json_encode($value, self::FLAGS);
        if ($raw === false) {
            // Don't lose the error envelope shape — emit a minimal valid JSON.
            return "{\n  \"error\": {\n    \"code\": \"encode_failed\",\n    \"message\": "
                . json_encode(json_last_error_msg() ?: 'json_encode failed', self::FLAGS) . "\n  }\n}\n";
        }
        // 4-space → 2-space at line starts only. ^ + multi-line flag means
        // we never touch indentation inside string values (PHP itself emits
        // `"key": "..."`, and indent only appears at the start of a line).
        $two = preg_replace_callback(
            '/^( {4})+/m',
            static fn ($m) => str_repeat('  ', strlen($m[0]) / 4),
            $raw
        );
        return $two . "\n";
    }

    /** Build a JsonResponse with the contract pretty shape. */
    public static function response(mixed $value, int $status = 200, array $headers = []): Response
    {
        $body = self::encode($value);
        $headers = array_merge([
            'Content-Type' => 'application/json',
            'Content-Length' => (string) strlen($body),
        ], $headers);
        return new Response($body, $status, $headers);
    }

    /**
     * Convenience: build the standard error envelope and serialise it.
     *
     * @param string $code        Stable error code (e.g. 'handle_taken').
     * @param string $message     Human-readable message.
     * @param string $requestId   X-Request-Id; pass '' if absent.
     * @param mixed  $details     Optional details array (omitted when null).
     */
    public static function error(int $status, string $code, string $message, string $requestId, mixed $details = null): Response
    {
        $body = ['error' => ['code' => $code, 'message' => $message, 'request_id' => $requestId]];
        if ($details !== null) {
            $body['error']['details'] = $details;
        }
        return self::response($body, $status);
    }
}
