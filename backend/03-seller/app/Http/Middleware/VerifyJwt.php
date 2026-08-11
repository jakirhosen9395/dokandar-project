<?php

namespace App\Http\Middleware;

use Closure;
use Firebase\JWT\JWT;
use Firebase\JWT\Key;
use Firebase\JWT\ExpiredException;
use Firebase\JWT\SignatureInvalidException;
use Illuminate\Http\Request;
use Illuminate\Http\JsonResponse;

/**
 * Verifies an RS256 access token issued by dokandar-auth. Reads
 * JWT_PUBLIC_KEY_B64 (base64-encoded PEM) from env, decodes once at
 * boot, then verifies on every request. Sets user_id + role on the
 * request attributes so controllers can read them.
 */
class VerifyJwt
{
    public function handle(Request $request, Closure $next)
    {
        $hdr = $request->header('Authorization', '');
        if (! str_starts_with($hdr, 'Bearer ')) {
            return self::err(401, 'token_missing', 'Missing Authorization: Bearer header', $request);
        }
        $token = substr($hdr, 7);

        $b64 = config('shop.jwt.public_key_b64');
        if (empty($b64) || $b64 === 'CHANGE_ME') {
            return self::err(500, 'jwt_misconfigured', 'JWT_PUBLIC_KEY_B64 is not configured', $request);
        }
        $pem = base64_decode($b64, true);
        if ($pem === false) {
            return self::err(500, 'jwt_misconfigured', 'JWT_PUBLIC_KEY_B64 is not valid base64', $request);
        }

        try {
            $claims = (array) JWT::decode($token, new Key($pem, 'RS256'));
        } catch (ExpiredException $e) {
            return self::err(401, 'token_expired', 'Access token has expired (use /refresh)', $request);
        } catch (SignatureInvalidException $e) {
            return self::err(401, 'token_invalid', 'Token signature invalid', $request);
        } catch (\Throwable $e) {
            return self::err(401, 'token_invalid', 'Invalid access token ('.$e->getMessage().')', $request);
        }
        $expectedIss = config('shop.jwt.issuer');
        if (! empty($expectedIss) && (($claims['iss'] ?? null) !== $expectedIss)) {
            return self::err(401, 'token_invalid', 'Bad issuer claim', $request);
        }
        // §16-h: audience enforcement — only when JWT_AUDIENCE is set. Default
        // empty (the deployed 01-auth mints no `aud` claim yet); enabling it
        // before auth issues one would reject every token.
        $expectedAud = config('shop.jwt.audience');
        if (! empty($expectedAud)) {
            $aud = $claims['aud'] ?? null;
            $audOk = is_array($aud) ? in_array($expectedAud, $aud, true) : ($aud === $expectedAud);
            if (! $audOk) {
                return self::err(401, 'token_invalid', 'Bad audience claim', $request);
            }
        }
        $sub = $claims['sub'] ?? null;
        if (empty($sub)) {
            return self::err(401, 'token_invalid', 'Missing sub claim', $request);
        }
        $request->attributes->set('user_id', $sub);
        $request->attributes->set('role', $claims['role'] ?? '');
        return $next($request);
    }

    private static function err(int $status, string $code, string $message, Request $r): JsonResponse
    {
        return new JsonResponse(
            ['error' => [
                'code' => $code,
                'message' => $message,
                'request_id' => $r->header('X-Request-Id'),
            ]],
            $status,
            [],
            JSON_PRETTY_PRINT | JSON_UNESCAPED_UNICODE
        );
    }
}
