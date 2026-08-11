using Grpc.Core;
using Dokandar.CouponRpc;
using Coupon.Auth;
using Coupon.Dtos;
using Coupon.Services;

namespace Coupon.Grpc;

// Realizes the architecture's gRPC contract: Coupon.ValidateCoupon @9090 (east-west; cart + order).
public class CouponGrpcService(ValidationService validation) : Dokandar.CouponRpc.Coupon.CouponBase
{
    public override async Task<ValidateCouponReply> ValidateCoupon(ValidateCouponRequest req, ServerCallContext ctx)
    {
        var tok = ctx.RequestHeaders.GetValue("x-internal-token");
        if (!string.IsNullOrEmpty(Config.InternalServiceToken) && !InternalToken.Valid(tok))
            throw new RpcException(new Status(StatusCode.Unauthenticated, "x-internal-token missing or invalid"));

        var body = new ValidateCouponBody
        {
            Code = req.Code ?? "",
            UserId = Guid.TryParse(req.UserId, out var u) ? u : Guid.Empty,
            ShopId = Guid.TryParse(req.ShopId, out var s) ? s : null,
            SubtotalMinor = req.SubtotalMinor,
        };
        var r = await validation.ValidateAsync(body);
        return new ValidateCouponReply
        {
            Valid = r.Valid,
            DiscountMinor = r.DiscountMinor,
            Reason = r.Reason ?? "",
            CouponId = r.CouponId?.ToString() ?? "",
            FundedBy = r.FundedBy ?? "",
            StacksWithSale = r.StacksWithSale,
        };
    }
}
