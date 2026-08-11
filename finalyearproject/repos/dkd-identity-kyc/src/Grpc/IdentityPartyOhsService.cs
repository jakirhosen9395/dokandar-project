// gRPC implementation of identity-party-ohs (the Party read model + PII resolver, R7).
using Dkd.Platform;
using Grpc.Core;
using IdentitySvc.Application;

namespace IdentitySvc.Grpc;

public sealed class IdentityPartyOhsService(PartyService svc) : IdentityPartyOhs.IdentityPartyOhsBase
{
    public override async Task<PartyReply> ResolveParty(ResolvePartyRequest request, ServerCallContext context)
    {
        var p = await ResolveGuarded(request.Did, context.CancellationToken);
        if (p is null) return new PartyReply { Found = false };
        return new PartyReply
        {
            Found = true, Did = p.Did, KycTier = p.KycTier, Status = p.Status, Locale = p.Locale,
            Phone = p.Phone, KycSubmitted = p.KycSubmitted, Bin = p.Bin ?? "",
            CreatedAt = p.CreatedAt, UpdatedAt = p.UpdatedAt,
        };
    }

    public override async Task<KycTierReply> GetKycTier(GetKycTierRequest request, ServerCallContext context)
    {
        var p = await ResolveGuarded(request.Did, context.CancellationToken);
        return p is null
            ? new KycTierReply { Found = false }
            : new KycTierReply { Found = true, Did = p.Did, KycTier = p.KycTier };
    }

    private async Task<OhsParty?> ResolveGuarded(string did, CancellationToken ct)
    {
        try { return await svc.ResolveAsync(did, ct); }
        catch (Exception ex) when (ex is ArgumentException or DokandarException)
        {
            throw new RpcException(new Status(StatusCode.InvalidArgument, ex.Message));
        }
    }
}
