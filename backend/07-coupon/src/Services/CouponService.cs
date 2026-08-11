using System.Text.Json;
using Microsoft.EntityFrameworkCore;
using Npgsql;
using Coupon.Data;
using Coupon.Dtos;
using Coupon.Observability;

namespace Coupon.Services;

public class CouponService(CouponDbContext db, RedisService redis)
{
    static readonly JsonSerializerOptions J = new() { PropertyNamingPolicy = JsonNamingPolicy.SnakeCaseLower };

    static CouponDto ToDto(CouponEntity c) => new(c.Id, c.Code, c.Kind, c.Scope, c.FundedBy, c.ShopId,
        c.ValuePercent, c.ValueMinor, c.MaxDiscountMinor, c.MinSpendMinor, c.ValidFrom, c.ValidUntil,
        c.MaxRedemptions, c.MaxPerUser, c.DraftedBy, c.ApprovedBy, c.State, c.CreatedAt, c.UpdatedAt);
    static FestivalDto ToDto(Festival f) => new(f.Id, f.Slug, f.NameBn, f.NameEn, f.StartsAt, f.EndsAt,
        f.BannerS3Key, f.TemplateKind, f.TemplateValuePercent, f.TemplateValueMinor, f.TemplateMaxDiscountMinor, f.FundedByDefault);

    static OutboxMessage Outbox(string topic, string key, object payload) =>
        new() { Topic = topic, Key = key, Payload = JsonSerializer.Serialize(payload, J), CreatedAt = DateTime.UtcNow };
    static bool IsUnique(DbUpdateException e) => e.InnerException is PostgresException { SqlState: "23505" };

    public async Task<CouponDto> DraftAsync(CouponDraftBody b, string sub)
    {
        var now = DateTime.UtcNow;
        var c = new CouponEntity
        {
            Id = Guid.NewGuid(), Code = b.Code, Kind = b.Kind, Scope = b.Scope, FundedBy = b.FundedBy,
            ShopId = b.ShopId, ValuePercent = (short?)b.ValuePercent, ValueMinor = b.ValueMinor,
            MaxDiscountMinor = b.MaxDiscountMinor, MinSpendMinor = b.MinSpendMinor,
            ValidFrom = b.ValidFrom.ToUniversalTime(), ValidUntil = b.ValidUntil.ToUniversalTime(),
            MaxRedemptions = b.MaxRedemptions, MaxPerUser = b.MaxPerUser, DraftedBy = Guid.Parse(sub),
            ApprovedBy = null, State = "draft", CreatedAt = now, UpdatedAt = now,
        };
        db.Coupons.Add(c);
        db.Outbox.Add(Outbox(Config.TopicDrafted, c.Id.ToString(), new
        {
            @event = "CouponDrafted", coupon_id = c.Id, code = c.Code, shop_id = c.ShopId, scope = c.Scope,
            drafted_by = c.DraftedBy, drafted_at = now.ToString("o"),
        }));
        try { await db.SaveChangesAsync(); }
        catch (DbUpdateException e) when (IsUnique(e)) { throw new ApiException(409, "code_taken", $"coupon code already exists: {b.Code}"); }
        await redis.BustShopAsync(c.ShopId);
        Metrics.CouponDrafts.WithLabels(Metrics.Svc, c.Scope).Inc();
        Log.Info("coupon.service", $"drafted coupon {c.Code} id={c.Id} scope={c.Scope} by={sub}");
        return ToDto(c);
    }

    public async Task<List<CouponDto>> ListMineAsync(string sub, bool isAdmin)
    {
        var q = db.Coupons.AsNoTracking().AsQueryable();
        if (!isAdmin) { var id = Guid.Parse(sub); q = q.Where(c => c.DraftedBy == id || c.ApprovedBy == id); }
        return (await q.OrderByDescending(c => c.CreatedAt).Take(50).ToListAsync()).Select(ToDto).ToList();
    }

    public async Task<CouponDto> GetOneAsync(Guid id)
        => ToDto(await db.Coupons.AsNoTracking().FirstOrDefaultAsync(x => x.Id == id)
                 ?? throw new ApiException(404, "not_found", "coupon not found"));

    public async Task<CouponDto> ApproveAsync(Guid id, string approver)
    {
        await using var tx = await db.Database.BeginTransactionAsync();
        var c = (await db.Coupons.FromSqlRaw("SELECT * FROM coupons WHERE id = {0} FOR UPDATE", id).ToListAsync()).FirstOrDefault()
                ?? throw new ApiException(404, "not_found", "coupon not found");
        if (c.State != "draft") throw new ApiException(409, "not_draft", $"coupon state is {c.State}, expected draft");
        if (c.DraftedBy.ToString() == approver) throw new ApiException(403, "self_approval_forbidden", "approver must differ from drafter (four-eyes)");
        var now = DateTime.UtcNow;
        var next = (c.ValidFrom <= now && now < c.ValidUntil) ? "active" : "approved";
        c.ApprovedBy = Guid.Parse(approver); c.State = next; c.UpdatedAt = now;
        db.Outbox.Add(Outbox(Config.TopicApproved, c.Id.ToString(), new
        {
            @event = "CouponApproved", coupon_id = c.Id, code = c.Code, shop_id = c.ShopId,
            approved_by = c.ApprovedBy, next_state = next, approved_at = now.ToString("o"),
        }));
        await db.SaveChangesAsync();
        await tx.CommitAsync();
        await redis.BustShopAsync(c.ShopId);
        Metrics.CouponApprovals.WithLabels(Metrics.Svc).Inc();
        Log.Info("coupon.service", $"approved coupon {c.Id} -> {next} by={approver}");
        return ToDto(c);
    }

    public async Task<CouponDto> RevokeAsync(Guid id, string actor, bool isAdmin)
    {
        await using var tx = await db.Database.BeginTransactionAsync();
        var c = (await db.Coupons.FromSqlRaw("SELECT * FROM coupons WHERE id = {0} FOR UPDATE", id).ToListAsync()).FirstOrDefault()
                ?? throw new ApiException(404, "not_found", "coupon not found");
        if (c.State is "revoked" or "expired") throw new ApiException(409, "already_terminal", $"coupon already in terminal state {c.State}");
        if (!isAdmin && c.DraftedBy.ToString() != actor) throw new ApiException(403, "insufficient_role", "only the drafter or an admin can revoke");
        var now = DateTime.UtcNow;
        c.State = "revoked"; c.UpdatedAt = now;
        db.Outbox.Add(Outbox(Config.TopicRevoked, c.Id.ToString(), new
        {
            @event = "CouponRevoked", coupon_id = c.Id, code = c.Code, revoked_by = actor, revoked_at = now.ToString("o"),
        }));
        await db.SaveChangesAsync();
        await tx.CommitAsync();
        await redis.BustShopAsync(c.ShopId);
        Metrics.CouponRevocations.WithLabels(Metrics.Svc).Inc();
        Log.Info("coupon.service", $"revoked coupon {c.Id} by={actor}");
        return ToDto(c);
    }

    public async Task<List<FestivalDto>> FestivalsListAsync()
    {
        var now = DateTime.UtcNow;
        return (await db.Festivals.AsNoTracking().Where(f => f.StartsAt <= now && f.EndsAt >= now)
            .OrderBy(f => f.StartsAt).ToListAsync()).Select(ToDto).ToList();
    }

    public async Task<FestivalDto> FestivalCreateAsync(FestivalCreateBody b, string sub)
    {
        var f = new Festival
        {
            Id = Guid.NewGuid(), Slug = b.Slug, NameBn = b.NameBn, NameEn = b.NameEn,
            StartsAt = b.StartsAt.ToUniversalTime(), EndsAt = b.EndsAt.ToUniversalTime(), BannerS3Key = b.BannerS3Key,
            TemplateKind = b.TemplateKind, TemplateValuePercent = (short?)b.TemplateValuePercent,
            TemplateValueMinor = b.TemplateValueMinor, TemplateMaxDiscountMinor = b.TemplateMaxDiscountMinor,
            FundedByDefault = b.FundedByDefault, CreatedBy = Guid.Parse(sub), CreatedAt = DateTime.UtcNow,
        };
        db.Festivals.Add(f);
        try { await db.SaveChangesAsync(); }
        catch (DbUpdateException e) when (IsUnique(e)) { throw new ApiException(409, "slug_taken", $"festival slug already exists: {b.Slug}"); }
        Log.Info("coupon.service", $"festival created {f.Slug} id={f.Id}");
        return ToDto(f);
    }

    public async Task<Dictionary<string, object>> FestivalOptInAsync(Guid festivalId, FestivalOptInBody b)
    {
        if (!await db.Festivals.AsNoTracking().AnyAsync(f => f.Id == festivalId))
            throw new ApiException(404, "not_found", "festival not found");
        var existing = await db.FestivalShops.FirstOrDefaultAsync(fs => fs.FestivalId == festivalId && fs.ShopId == b.ShopId);
        if (existing != null)
        {
            existing.OverrideValuePercent = (short?)b.OverrideValuePercent;
            existing.OverrideValueMinor = b.OverrideValueMinor;
        }
        else
        {
            db.FestivalShops.Add(new FestivalShop { Id = Guid.NewGuid(), FestivalId = festivalId, ShopId = b.ShopId, OptedInAt = DateTime.UtcNow, OverrideValuePercent = (short?)b.OverrideValuePercent, OverrideValueMinor = b.OverrideValueMinor });
        }
        try { await db.SaveChangesAsync(); }
        catch (DbUpdateException) { throw new ApiException(500, "db_error", "could not record opt-in"); }
        return new Dictionary<string, object> { ["ok"] = true, ["festival_id"] = festivalId.ToString(), ["shop_id"] = b.ShopId.ToString() };
    }
}
