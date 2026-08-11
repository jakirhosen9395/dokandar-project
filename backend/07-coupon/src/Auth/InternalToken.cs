using System.Security.Cryptography;
using System.Text;

namespace Coupon.Auth;

public static class InternalToken
{
    // Constant-time comparison; fail-closed on empty.
    public static bool Valid(string? presented)
    {
        var expected = Config.InternalServiceToken;
        if (string.IsNullOrEmpty(expected) || string.IsNullOrEmpty(presented)) return false;
        var a = Encoding.UTF8.GetBytes(presented);
        var b = Encoding.UTF8.GetBytes(expected);
        return CryptographicOperations.FixedTimeEquals(a, b);
    }
}
