using System.ComponentModel.DataAnnotations.Schema;

namespace Coupon.Data;

// Entities map to the SQL-created tables (migrations/0001_init.sql) via snake_case naming convention.
[Table("coupons")]
public class CouponEntity
{
    public Guid Id { get; set; }
    public string Code { get; set; } = "";
    public string Kind { get; set; } = "";          // percent|fixed|free_delivery|min_spend|first_order
    public string Scope { get; set; } = "";          // shop|platform
    public string FundedBy { get; set; } = "";       // shopkeeper|platform
    public Guid? ShopId { get; set; }
    public short? ValuePercent { get; set; }
    public int? ValueMinor { get; set; }
    public int? MaxDiscountMinor { get; set; }
    public int? MinSpendMinor { get; set; }
    public DateTime ValidFrom { get; set; }
    public DateTime ValidUntil { get; set; }
    public int? MaxRedemptions { get; set; }
    public int MaxPerUser { get; set; } = 1;
    public Guid DraftedBy { get; set; }
    public Guid? ApprovedBy { get; set; }
    public string State { get; set; } = "draft";     // draft|approved|active|expired|revoked
    public DateTime CreatedAt { get; set; }
    public DateTime UpdatedAt { get; set; }
}

[Table("coupon_redemptions")]
public class CouponRedemption
{
    public Guid Id { get; set; }
    public Guid CouponId { get; set; }
    public Guid UserId { get; set; }
    public Guid OrderId { get; set; }
    public Guid? SubOrderId { get; set; }
    public int AmountMinor { get; set; }
    public DateTime RedeemedAt { get; set; }
}

[Table("festivals")]
public class Festival
{
    public Guid Id { get; set; }
    public string Slug { get; set; } = "";
    public string NameBn { get; set; } = "";
    public string NameEn { get; set; } = "";
    public DateTime StartsAt { get; set; }
    public DateTime EndsAt { get; set; }
    [Column("banner_s3_key")] public string? BannerS3Key { get; set; }
    public string TemplateKind { get; set; } = "";
    public short? TemplateValuePercent { get; set; }
    public int? TemplateValueMinor { get; set; }
    public int? TemplateMaxDiscountMinor { get; set; }
    public string FundedByDefault { get; set; } = "shopkeeper";
    public Guid CreatedBy { get; set; }
    public DateTime CreatedAt { get; set; }
}

[Table("festival_shops")]
public class FestivalShop
{
    public Guid Id { get; set; }
    public Guid FestivalId { get; set; }
    public Guid ShopId { get; set; }
    public DateTime OptedInAt { get; set; }
    public short? OverrideValuePercent { get; set; }
    public int? OverrideValueMinor { get; set; }
}

[Table("outbox")]
public class OutboxMessage
{
    public long Id { get; set; }
    public string Topic { get; set; } = "";
    public string? Key { get; set; }
    public string Payload { get; set; } = "{}";   // jsonb
    public DateTime CreatedAt { get; set; }
    public DateTime? SentAt { get; set; }
}
