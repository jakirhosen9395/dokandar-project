namespace Coupon.Dtos;

// JSON uses snake_case (PropertyNamingPolicy = SnakeCaseLower in Program.cs).
public record CouponDto(Guid Id, string Code, string Kind, string Scope, string FundedBy, Guid? ShopId,
    int? ValuePercent, int? ValueMinor, int? MaxDiscountMinor, int? MinSpendMinor,
    DateTime ValidFrom, DateTime ValidUntil, int? MaxRedemptions, int MaxPerUser,
    Guid DraftedBy, Guid? ApprovedBy, string State, DateTime CreatedAt, DateTime UpdatedAt);

public record FestivalDto(Guid Id, string Slug, string NameBn, string NameEn, DateTime StartsAt, DateTime EndsAt,
    string? BannerS3Key, string TemplateKind, int? TemplateValuePercent, int? TemplateValueMinor,
    int? TemplateMaxDiscountMinor, string FundedByDefault);

public class CouponDraftBody
{
    public string Code { get; set; } = "";
    public string Kind { get; set; } = "";
    public string Scope { get; set; } = "";
    public string FundedBy { get; set; } = "";
    public Guid? ShopId { get; set; }
    public int? ValuePercent { get; set; }
    public int? ValueMinor { get; set; }
    public int? MaxDiscountMinor { get; set; }
    public int? MinSpendMinor { get; set; }
    public DateTime ValidFrom { get; set; }
    public DateTime ValidUntil { get; set; }
    public int? MaxRedemptions { get; set; }
    public int MaxPerUser { get; set; } = 1;
}

public class FestivalCreateBody
{
    public string Slug { get; set; } = "";
    public string NameBn { get; set; } = "";
    public string NameEn { get; set; } = "";
    public DateTime StartsAt { get; set; }
    public DateTime EndsAt { get; set; }
    public string? BannerS3Key { get; set; }
    public string TemplateKind { get; set; } = "";
    public int? TemplateValuePercent { get; set; }
    public int? TemplateValueMinor { get; set; }
    public int? TemplateMaxDiscountMinor { get; set; }
    public string FundedByDefault { get; set; } = "shopkeeper";
}

public class FestivalOptInBody
{
    public Guid ShopId { get; set; }
    public int? OverrideValuePercent { get; set; }
    public int? OverrideValueMinor { get; set; }
}

public class ValidateCouponBody
{
    public string Code { get; set; } = "";
    public Guid UserId { get; set; }
    public long SubtotalMinor { get; set; }
    public Guid? ShopId { get; set; }
    public Guid? OrderId { get; set; }
}

public record ValidateCouponResponse(bool Valid, long DiscountMinor, string? Reason, Guid? CouponId,
    string? FundedBy, bool StacksWithSale);
