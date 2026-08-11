// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-05: W3C Trace Context (traceparent) parse / format / inject / extract, replacing the bare
// header passthrough. Full OTel-SDK span lifecycle is a service concern; the SDK guarantees a
// correct wire header so trace context flows across HTTP calls AND event headers (wired into
// OutboxRelay.Headers). Format: "version-traceid-spanid-flags" =
//   00 - 32 hex (non-zero) - 16 hex (non-zero) - 2 hex.  Canon: R6 spine carries trace context.

namespace Dkd.Platform;

using System.Security.Cryptography;

/// <summary>A parsed W3C <c>traceparent</c>. Fields are lowercase hex of the fixed canonical widths.</summary>
public sealed record Traceparent(string Version, string TraceId, string SpanId, string Flags)
{
    /// <summary>Render back to the canonical <c>version-traceid-spanid-flags</c> wire string.</summary>
    public string Format() => $"{Version}-{TraceId}-{SpanId}-{Flags}";
}

/// <summary>
/// W3C Trace Context helpers. Parses/normalises the <c>traceparent</c> header, mints new
/// trace/span ids, and injects/extracts the header on outgoing HTTP requests and event headers.
/// </summary>
public static class W3CTrace
{
    public const string HeaderName = "traceparent";
    private const string Version00 = "00";
    private const string Sampled = "01";

    /// <summary>Parse and validate a traceparent; returns null when malformed (never throws).</summary>
    public static Traceparent? Parse(string? header)
    {
        if (string.IsNullOrEmpty(header)) return null;
        var parts = header.Split('-');
        if (parts.Length != 4) return null;

        var (ver, trace, span, flags) = (parts[0], parts[1], parts[2], parts[3]);
        if (!IsHex(ver, 2) || ver == "ff") return null;            // "ff" is the forbidden/invalid version
        if (!IsHex(trace, 32) || IsAllZero(trace)) return null;    // all-zero trace-id is invalid
        if (!IsHex(span, 16) || IsAllZero(span)) return null;      // all-zero parent-id is invalid
        if (!IsHex(flags, 2)) return null;
        return new Traceparent(ver, trace, span, flags);
    }

    /// <summary>Non-throwing parse into <paramref name="traceparent"/>; true on success.</summary>
    public static bool TryParse(string? header, out Traceparent? traceparent)
    {
        traceparent = Parse(header);
        return traceparent is not null;
    }

    /// <summary>Mint a fresh root traceparent (new 128-bit trace-id + 64-bit span-id, sampled).</summary>
    public static Traceparent NewRootSpan() => new(Version00, NewTraceId(), NewSpanId(), Sampled);

    /// <summary>A child traceparent under <paramref name="parent"/>'s trace-id with a fresh span-id.</summary>
    public static Traceparent NewChildSpan(Traceparent parent)
    {
        ArgumentNullException.ThrowIfNull(parent);
        return parent with { SpanId = NewSpanId() };
    }

    /// <summary>New 128-bit trace-id as 32 lowercase-hex chars (never all-zero).</summary>
    public static string NewTraceId() => RandomHex(16);

    /// <summary>New 64-bit span-id as 16 lowercase-hex chars (never all-zero).</summary>
    public static string NewSpanId() => RandomHex(8);

    /// <summary>Inject the traceparent into an outgoing HTTP / event header map.</summary>
    public static void Inject(IDictionary<string, string> headers, Traceparent traceparent)
    {
        ArgumentNullException.ThrowIfNull(headers);
        ArgumentNullException.ThrowIfNull(traceparent);
        headers[HeaderName] = traceparent.Format();
    }

    /// <summary>Extract and validate the traceparent from an inbound header map; null when absent/malformed.</summary>
    public static Traceparent? Extract(IReadOnlyDictionary<string, string> headers)
    {
        ArgumentNullException.ThrowIfNull(headers);
        return headers.TryGetValue(HeaderName, out var raw) ? Parse(raw) : null;
    }

    private static string RandomHex(int bytes)
    {
        Span<byte> b = stackalloc byte[16];
        b = b[..bytes];
        do { RandomNumberGenerator.Fill(b); } while (AllZero(b));
        return Convert.ToHexString(b).ToLowerInvariant();
    }

    private static bool IsHex(string s, int len)
    {
        if (s.Length != len) return false;
        foreach (var c in s)
            if (!Uri.IsHexDigit(c) || char.IsUpper(c)) return false; // canon lowercase hex only
        return true;
    }

    private static bool IsAllZero(string hex)
    {
        foreach (var c in hex) if (c != '0') return false;
        return true;
    }

    private static bool AllZero(ReadOnlySpan<byte> b)
    {
        foreach (var x in b) if (x != 0) return false;
        return true;
    }
}
