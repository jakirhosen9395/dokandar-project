namespace Coupon;

// Maps to the {"error":{"code","message","request_id"}} envelope at the boundary.
public sealed class ApiException(int status, string code, string message) : Exception(message)
{
    public int Status { get; } = status;
    public string Code { get; } = code;
}
