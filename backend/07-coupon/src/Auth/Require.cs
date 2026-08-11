namespace Coupon.Auth;

// Bearer/role gates — throw ApiException mapped to the error envelope by the boundary middleware.
public static class Require
{
    public static AuthUser User(HttpContext ctx)
    {
        if (string.IsNullOrEmpty(Config.JwtPublicKeyB64))
            throw new ApiException(503, "server_misconfigured", "JWT_PUBLIC_KEY_B64 not configured");
        var auth = ctx.Request.Headers.Authorization.ToString();
        if (string.IsNullOrEmpty(auth) || !auth.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase))
            throw new ApiException(401, "missing_token", "Bearer token required");
        return Jwt.Verify(auth) ?? throw new ApiException(401, "invalid_token", "invalid or expired token");
    }
    public static AuthUser Shopkeeper(HttpContext ctx)
    {
        var u = User(ctx);
        if (!u.IsShopkeeper) throw new ApiException(403, "insufficient_role", "shopkeeper or admin required");
        return u;
    }
    public static AuthUser Admin(HttpContext ctx)
    {
        var u = User(ctx);
        if (!u.IsAdmin) throw new ApiException(403, "insufficient_role", "admin or platform_staff required");
        return u;
    }
}
