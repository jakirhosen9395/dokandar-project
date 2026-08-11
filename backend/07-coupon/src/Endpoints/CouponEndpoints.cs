using Coupon.Auth;
using Coupon.Dtos;
using Coupon.Services;

namespace Coupon.Endpoints;

public static class CouponEndpoints
{
    static readonly HashSet<string> Kinds = new() { "percent", "fixed", "free_delivery", "min_spend", "first_order" };

    public static void MapCouponEndpoints(this IEndpointRouteBuilder app)
    {
        var g = app.MapGroup("/api/v1/coupon").WithTags("coupon");

        g.MapPost("/coupons", async (HttpContext ctx, CouponDraftBody body, CouponService svc) =>
        {
            var u = Require.Shopkeeper(ctx);
            if (string.IsNullOrWhiteSpace(body.Code) || body.Code.Length is < 3 or > 40) throw new ApiException(422, "invalid_request", "code must be 3-40 chars");
            if (!Kinds.Contains(body.Kind)) throw new ApiException(422, "invalid_request", "kind must be percent|fixed|free_delivery|min_spend|first_order");
            if (body.Scope is not ("shop" or "platform")) throw new ApiException(422, "invalid_request", "scope must be shop|platform");
            if (body.FundedBy is not ("shopkeeper" or "platform")) throw new ApiException(422, "invalid_request", "funded_by must be shopkeeper|platform");
            if (body.Scope == "platform" && !u.IsAdmin) throw new ApiException(403, "insufficient_role", "platform-scope coupons require admin");
            if (body.Scope == "shop" && body.ShopId is null) throw new ApiException(422, "invalid_request", "shop_id is required for scope='shop'");
            if (body.Kind == "percent" && (body.ValuePercent is null or 0)) throw new ApiException(422, "invalid_request", "value_percent is required for kind='percent'");
            if (body.Kind == "fixed" && (body.ValueMinor is null or 0)) throw new ApiException(422, "invalid_request", "value_minor is required for kind='fixed'");
            return Results.Json(await svc.DraftAsync(body, u.Sub), statusCode: 201);
        }).WithName("draftCoupon")
          .WithSummary("Draft a coupon (shopkeeper or admin)")
          .WithDescription("Creates a coupon template in `draft` state. Money fields are integer **paisa** (BDT minor units). `kind` ∈ {percent, fixed, free_delivery, min_spend, first_order}; `scope` ∈ {shop, platform} (platform requires admin); `funded_by` ∈ {shopkeeper, platform}. Four-eyes approval means a different shopkeeper/admin must approve before the coupon activates.")
          .Produces<CouponDto>(201);

        g.MapGet("/coupons/me", async (HttpContext ctx, CouponService svc) =>
        {
            var u = Require.User(ctx);
            return Results.Json(await svc.ListMineAsync(u.Sub, u.IsAdmin));
        }).WithName("listMyCoupons")
          .WithSummary("List my coupons (drafter or approver)")
          .WithDescription("Returns coupons drafted by the caller (admins see all). Requires a Bearer access token.")
          .Produces<List<CouponDto>>();

        g.MapGet("/coupons/{id}", async (HttpContext ctx, string id, CouponService svc) =>
        {
            Require.User(ctx);
            if (!Guid.TryParse(id, out var gid)) throw new ApiException(404, "not_found", "coupon not found");
            return Results.Json(await svc.GetOneAsync(gid));
        }).WithName("getCoupon")
          .WithSummary("Get a single coupon")
          .WithDescription("Fetches one coupon by its UUID. Returns `404 not_found` for an unknown or malformed id.")
          .Produces<CouponDto>();

        g.MapPost("/coupons/{id}/approve", async (HttpContext ctx, string id, CouponService svc) =>
        {
            var u = Require.Shopkeeper(ctx);
            if (!Guid.TryParse(id, out var gid)) throw new ApiException(404, "not_found", "coupon not found");
            return Results.Json(await svc.ApproveAsync(gid, u.Sub));
        }).WithName("approveCoupon")
          .WithSummary("Approve a coupon (four-eyes — approver != drafter)")
          .WithDescription("Transitions a `draft` coupon to `approved`/`active`. The approver must differ from the drafter (four-eyes control), otherwise the request is rejected.")
          .Produces<CouponDto>();

        g.MapPost("/coupons/{id}/revoke", async (HttpContext ctx, string id, CouponService svc) =>
        {
            var u = Require.Shopkeeper(ctx);
            if (!Guid.TryParse(id, out var gid)) throw new ApiException(404, "not_found", "coupon not found");
            return Results.Json(await svc.RevokeAsync(gid, u.Sub, u.IsAdmin));
        }).WithName("revokeCoupon")
          .WithSummary("Revoke a coupon (drafter or admin)")
          .WithDescription("Moves a coupon to the `revoked` state. Only the original drafter or an admin may revoke.")
          .Produces<CouponDto>();

        g.MapGet("/festivals", async (CouponService svc) => Results.Json(await svc.FestivalsListAsync()))
            .WithName("listFestivals")
            .WithSummary("List active festival campaigns")
            .WithDescription("Public list of currently active festival campaign templates (e.g. Eid, Pohela Boishakh). No authentication required.")
            .Produces<List<FestivalDto>>();

        g.MapPost("/festivals", async (HttpContext ctx, FestivalCreateBody body, CouponService svc) =>
        {
            var u = Require.Admin(ctx);
            if (string.IsNullOrWhiteSpace(body.Slug) || body.Slug.Length is < 3 or > 40) throw new ApiException(422, "invalid_request", "slug must be 3-40 chars");
            if (!Kinds.Contains(body.TemplateKind)) throw new ApiException(422, "invalid_request", "template_kind invalid");
            return Results.Json(await svc.FestivalCreateAsync(body, u.Sub), statusCode: 201);
        }).WithName("createFestival")
          .WithSummary("Create a festival campaign template (admin)")
          .WithDescription("Admin-only. Defines a festival campaign template that shops can opt into. `slug` is 3–40 chars; `template_kind` ∈ {percent, fixed, free_delivery, min_spend, first_order}. Template money fields are integer paisa.")
          .Produces<FestivalDto>(201);

        g.MapPost("/festivals/{id}/opt-in", async (HttpContext ctx, string id, FestivalOptInBody body, CouponService svc) =>
        {
            Require.Shopkeeper(ctx);
            if (!Guid.TryParse(id, out var gid)) throw new ApiException(404, "not_found", "festival not found");
            return Results.Json(await svc.FestivalOptInAsync(gid, body));
        }).WithName("optInFestival")
          .WithSummary("Shop opt-in to a festival campaign (+ optional override)")
          .WithDescription("Opt a shop into a festival campaign, optionally overriding the template percent/fixed value. Requires a shopkeeper/admin Bearer token.");

        g.MapPost("/validate", async (HttpContext ctx, ValidateCouponBody body, ValidationService svc) =>
        {
            var tok = ctx.Request.Headers["x-internal-token"].ToString();
            if (!string.IsNullOrEmpty(Config.InternalServiceToken) && !InternalToken.Valid(tok))
                throw new ApiException(401, "unauthorized", "x-internal-token missing or invalid");
            return Results.Json(await svc.ValidateAsync(body));
        }).WithName("validateCoupon")
          .WithSummary("ValidateCoupon (east-west — cart + order call this)")
          .WithDescription("Internal endpoint mirroring the `Coupon.ValidateCoupon` gRPC method; cart and order call it during checkout. Authenticated with the shared `x-internal-token` header (when configured), not a user Bearer token. Returns the computed `discount_minor` (paisa) and `funded_by`.")
          .Produces<ValidateCouponResponse>();
    }
}
