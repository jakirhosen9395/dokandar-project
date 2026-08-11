// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-04 (companion to Uuid7.cs): v7-aware layer over the generated prefixed-ID helpers in Ids.cs.
// The generated PrefixedId base stays lenient (existing services + fixtures construct ids from
// non-v7 external bodies), so this module adds an OPT-IN v7 policy: typed factories that mint
// prefix + fresh UUID v7, and a validator that checks the UUID embedded after a known prefix is
// a genuine v7. Adopt Ids7 where the platform mints its own identifiers.

namespace Dkd.Platform;

/// <summary>
/// v7-validating factories and checks for the prefixed identifiers declared in <see cref="PrefixedId"/>.
/// A prefixed id is "v7-valid" when its value starts with the type's canonical prefix AND the
/// remaining body is a genuine UUID v7 (see <see cref="Uuid7.IsValidV7"/>).
/// </summary>
public static class Ids7
{
    public static DID NewDid() => new(DID.Prefix + Uuid7.NewId());
    public static PPID NewPpid() => new(PPID.Prefix + Uuid7.NewId());
    public static GPID NewGpid() => new(GPID.Prefix + Uuid7.NewId());
    public static ORD NewOrd() => new(ORD.Prefix + Uuid7.NewId());
    public static TRD NewTrd() => new(TRD.Prefix + Uuid7.NewId());
    public static WLT NewWlt() => new(WLT.Prefix + Uuid7.NewId());
    public static ESC NewEsc() => new(ESC.Prefix + Uuid7.NewId());
    public static TXN NewTxn() => new(TXN.Prefix + Uuid7.NewId());
    public static SHP NewShp() => new(SHP.Prefix + Uuid7.NewId());
    public static NTF NewNtf() => new(NTF.Prefix + Uuid7.NewId());
    public static MFSA NewMfsa() => new(MFSA.Prefix + Uuid7.NewId());

    /// <summary>True when <paramref name="id"/>'s body (after its canonical prefix) is a valid UUID v7.</summary>
    public static bool IsValidV7(PrefixedId id)
    {
        ArgumentNullException.ThrowIfNull(id);
        return id switch
        {
            DID => Uuid7.IsValidV7(Body(id.Value, DID.Prefix)),
            PPID => Uuid7.IsValidV7(Body(id.Value, PPID.Prefix)),
            GPID => Uuid7.IsValidV7(Body(id.Value, GPID.Prefix)),
            ORD => Uuid7.IsValidV7(Body(id.Value, ORD.Prefix)),
            TRD => Uuid7.IsValidV7(Body(id.Value, TRD.Prefix)),
            WLT => Uuid7.IsValidV7(Body(id.Value, WLT.Prefix)),
            ESC => Uuid7.IsValidV7(Body(id.Value, ESC.Prefix)),
            TXN => Uuid7.IsValidV7(Body(id.Value, TXN.Prefix)),
            SHP => Uuid7.IsValidV7(Body(id.Value, SHP.Prefix)),
            NTF => Uuid7.IsValidV7(Body(id.Value, NTF.Prefix)),
            MFSA => Uuid7.IsValidV7(Body(id.Value, MFSA.Prefix)),
            _ => false,
        };
    }

    /// <summary>Return <paramref name="id"/> when its embedded UUID is v7; otherwise throw.</summary>
    public static T RequireV7<T>(T id) where T : PrefixedId
    {
        if (!IsValidV7(id))
            throw new ArgumentException($"{typeof(T).Name} body is not a valid UUID v7: {id.Value}", nameof(id));
        return id;
    }

    // Empty (never a valid v7) when the value does not carry the expected prefix.
    private static string Body(string value, string prefix) =>
        value.StartsWith(prefix, StringComparison.Ordinal) ? value[prefix.Length..] : string.Empty;
}
