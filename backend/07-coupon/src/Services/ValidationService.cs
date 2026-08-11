using System.Diagnostics;
using Microsoft.EntityFrameworkCore;
using Coupon.Data;
using Coupon.Dtos;
using Coupon.Observability;

namespace Coupon.Services;

// ValidateCoupon — the synchronous decision called east-west by 06-cart (quote) and 13-order (place).
// Read-only; never writes a redemption row (13-order does that under (coupon_id, order_id) UNIQUE).
public class ValidationService(CouponDbContext db)
{
    public async Task<ValidateCouponResponse> ValidateAsync(ValidateCouponBody body)
    {
        var sw = Stopwatch.StartNew();
        var result = "ok";
        try
        {
            var code = (body.Code ?? "").Trim();
            var c = await db.Coupons.AsNoTracking().FirstOrDefaultAsync(x => x.Code == code);
            if (c == null) { result = "not_found"; return Miss("not_found", null); }
            var now = DateTime.UtcNow;
            if (c.State is "draft" or "revoked" or "expired") { result = c.State; return Miss(c.State, c.Id); }
            if (c.ValidUntil <= now) { result = "expired"; return Miss("expired", c.Id); }
            if (c.ValidFrom > now) { result = "not_yet_valid"; return Miss("not_yet_valid", c.Id); }
            if (c.Scope == "shop" && body.ShopId.HasValue && c.ShopId != body.ShopId) { result = "wrong_shop"; return Miss("wrong_shop", c.Id); }
            if (c.MinSpendMinor is > 0 && body.SubtotalMinor < c.MinSpendMinor) { result = "min_spend"; return Miss("min_spend", c.Id); }
            if (c.MaxRedemptions.HasValue)
            {
                var total = await db.Redemptions.CountAsync(r => r.CouponId == c.Id);
                if (total >= c.MaxRedemptions) { result = "max_redemptions"; return Miss("max_redemptions", c.Id); }
            }
            var perUser = await db.Redemptions.CountAsync(r => r.CouponId == c.Id && r.UserId == body.UserId);
            if (perUser >= c.MaxPerUser) { result = "max_per_user"; return Miss("max_per_user", c.Id); }
            var discount = ComputeDiscount(c, body.SubtotalMinor);
            return new ValidateCouponResponse(true, discount, null, c.Id, c.FundedBy, true);
        }
        finally
        {
            Metrics.CouponValidations.WithLabels(Metrics.Svc, result).Inc();
            Metrics.CouponValidationMs.WithLabels(Metrics.Svc).Observe(sw.Elapsed.TotalMilliseconds);
        }
    }

    static ValidateCouponResponse Miss(string reason, Guid? id) => new(false, 0, reason, id, null, true);

    static long ComputeDiscount(CouponEntity c, long subtotal)
    {
        long d = c.Kind switch
        {
            "percent" => subtotal * (c.ValuePercent ?? 0) / 100,
            "fixed" => c.ValueMinor ?? 0,
            "free_delivery" or "min_spend" or "first_order" => c.ValueMinor ?? 0,
            _ => 0,
        };
        if (c.MaxDiscountMinor.HasValue) d = Math.Min(d, c.MaxDiscountMinor.Value);
        return Math.Max(0, Math.Min(d, subtotal));
    }
}
