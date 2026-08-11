package com.dokandar.order.auth;

import io.jsonwebtoken.Claims;
import io.jsonwebtoken.Jws;
import io.jsonwebtoken.Jwts;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.security.KeyFactory;
import java.security.PublicKey;
import java.security.spec.X509EncodedKeySpec;
import java.util.Base64;
import java.util.UUID;

/**
 * RS256 verify-only — the fleet shape. {@code JWT_PUBLIC_KEY_B64} is auth's PUBLIC
 * key delivered base64-encoded (full PEM with BEGIN/END); decode, strip markers,
 * decode the inner base64, import the DER as X509.
 *
 * <p>Contract (architecture.md §12 + the live-auth claim shape):
 * algorithm pinned to RS256 (explicit allowlist), issuer verified
 * ({@code dokandar-auth}), and {@code aud} is NOT enforced — the deployed auth
 * mints no {@code aud} claim, so requiring it would reject every token. Role is
 * the singular {@code role} string claim.
 */
@Component
public class JwtAuth {

    private final PublicKey publicKey;
    private final String issuer;

    public JwtAuth(@Value("${dokandar.jwt.public-key-b64:}") String pubKeyB64,
                   @Value("${dokandar.jwt.issuer:dokandar-auth}") String issuer,
                   @Value("${dokandar.service.app-env:dev}") String appEnv) {
        this.issuer = issuer;
        boolean prodLike = "stage".equals(appEnv) || "prod".equals(appEnv);
        if ((pubKeyB64 == null || pubKeyB64.isBlank()) && prodLike)
            throw new IllegalStateException("JWT_PUBLIC_KEY_B64 is empty under APP_ENV=" + appEnv + " (fail-fast)");
        PublicKey pk = null;
        try {
            if (pubKeyB64 != null && !pubKeyB64.isBlank()) {
                String pem = new String(Base64.getDecoder().decode(pubKeyB64));
                String stripped = pem
                        .replace("-----BEGIN PUBLIC KEY-----", "")
                        .replace("-----END PUBLIC KEY-----", "")
                        .replaceAll("\\s", "");
                byte[] der = Base64.getDecoder().decode(stripped);
                pk = KeyFactory.getInstance("RSA").generatePublic(new X509EncodedKeySpec(der));
            }
        } catch (Exception e) {
            throw new IllegalStateException("invalid JWT_PUBLIC_KEY_B64", e);
        }
        this.publicKey = pk;
    }

    public record AuthUser(UUID id, String role, String phone) {}

    /** Verifies a "Bearer <jwt>" header; throws {@link UnauthorizedException} on any failure. */
    public AuthUser verifyOrThrow(String bearer) {
        if (publicKey == null) throw new UnauthorizedException("server_misconfigured", "no JWT public key configured");
        if (bearer == null || !bearer.startsWith("Bearer "))
            throw new UnauthorizedException("token_missing", "Missing Authorization: Bearer header");
        String token = bearer.substring(7);
        try {
            Jws<Claims> jws = Jwts.parser()
                    .verifyWith(publicKey)
                    .requireIssuer(issuer)
                    .build()
                    .parseSignedClaims(token);
            String alg = jws.getHeader().getAlgorithm();
            if (!"RS256".equals(alg))                                   // explicit RS256 allowlist
                throw new UnauthorizedException("token_invalid", "unsupported alg " + alg);
            Claims c = jws.getPayload();
            String sub = c.getSubject();
            if (sub == null || sub.isBlank())
                throw new UnauthorizedException("token_invalid", "Token missing sub claim");
            return new AuthUser(UUID.fromString(sub), (String) c.get("role"), (String) c.get("phone"));
        } catch (UnauthorizedException e) {
            throw e;
        } catch (io.jsonwebtoken.ExpiredJwtException e) {
            throw new UnauthorizedException("token_expired", "Access token has expired (use /refresh)");
        } catch (Exception e) {
            throw new UnauthorizedException("token_invalid", "Invalid access token");
        }
    }

    public static class UnauthorizedException extends RuntimeException {
        public final String code;
        public UnauthorizedException(String code, String message) { super(message); this.code = code; }
    }
}
