using System.IdentityModel.Tokens.Jwt;
using System.Security.Cryptography;
using System.Text;
using Microsoft.IdentityModel.Tokens;

namespace Coupon.Auth;

public record AuthUser(string Sub, string Role)
{
    // role claim is a single lowercased string (matches 07-coupon auth/jwt.py)
    public bool IsAdmin => Role is "admin" or "platform_staff";
    public bool IsShopkeeper => Role is "shopkeeper" or "shop_staff" or "admin" or "platform_staff";
}

public static class Jwt
{
    static RsaSecurityKey? _key;
    static bool _tried;
    static RsaSecurityKey? Key()
    {
        if (_tried) return _key;
        _tried = true;
        if (string.IsNullOrEmpty(Config.JwtPublicKeyB64)) return null;
        try
        {
            var pem = Encoding.UTF8.GetString(Convert.FromBase64String(Config.JwtPublicKeyB64));
            var rsa = RSA.Create();
            rsa.ImportFromPem(pem);
            _key = new RsaSecurityKey(rsa);
        }
        catch (Exception e) { Console.Error.WriteLine($"JWT key load failed: {e.GetType().Name}: {e.Message}"); _key = null; }
        return _key;
    }

    public static AuthUser? Verify(string? authHeader)
    {
        if (string.IsNullOrEmpty(authHeader)) return null;
        var tok = authHeader.StartsWith("Bearer ", StringComparison.OrdinalIgnoreCase) ? authHeader[7..].Trim() : authHeader.Trim();
        if (tok.Length == 0) return null;
        var key = Key();
        if (key == null) return null;
        try
        {
            var handler = new JwtSecurityTokenHandler { MapInboundClaims = false };
            var prms = new TokenValidationParameters
            {
                ValidateIssuer = true,
                ValidIssuer = Config.JwtIssuer,
                ValidateAudience = false,
                ValidateIssuerSigningKey = true,
                IssuerSigningKey = key,
                ValidAlgorithms = new[] { "RS256" },
                ValidateLifetime = true,
                ClockSkew = TimeSpan.FromSeconds(30),
            };
            var principal = handler.ValidateToken(tok, prms, out _);
            var sub = principal.FindFirst("sub")?.Value ?? principal.FindFirst(JwtRegisteredClaimNames.Sub)?.Value ?? "";
            var role = (principal.FindFirst("role")?.Value ?? principal.FindFirst(System.Security.Claims.ClaimTypes.Role)?.Value ?? "").ToLowerInvariant();
            return string.IsNullOrEmpty(sub) ? null : new AuthUser(sub, role);
        }
        catch { return null; }
    }
}
