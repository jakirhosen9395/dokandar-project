using Microsoft.EntityFrameworkCore;

namespace Coupon.Data;

public class CouponDbContext(DbContextOptions<CouponDbContext> options) : DbContext(options)
{
    public DbSet<CouponEntity> Coupons => Set<CouponEntity>();
    public DbSet<CouponRedemption> Redemptions => Set<CouponRedemption>();
    public DbSet<Festival> Festivals => Set<Festival>();
    public DbSet<FestivalShop> FestivalShops => Set<FestivalShop>();
    public DbSet<OutboxMessage> Outbox => Set<OutboxMessage>();

    protected override void OnModelCreating(ModelBuilder b)
    {
        b.Entity<CouponEntity>().HasIndex(c => c.Code).IsUnique();
        b.Entity<CouponRedemption>().HasIndex(r => new { r.CouponId, r.OrderId }).IsUnique();
        b.Entity<Festival>().HasIndex(f => f.Slug).IsUnique();
        b.Entity<FestivalShop>().HasIndex(f => new { f.FestivalId, f.ShopId }).IsUnique();
        b.Entity<OutboxMessage>().Property(o => o.Payload).HasColumnType("jsonb");
    }
}
