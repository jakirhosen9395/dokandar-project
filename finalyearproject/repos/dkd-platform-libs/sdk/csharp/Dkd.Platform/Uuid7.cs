// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-04: real UUID v7 (RFC 9562) generator + strict validator. The generated Ids.cs prefixed
// helpers only check prefix+length; this module adds (a) a generator that puts the unix-ms
// timestamp in the high 48 bits, stamps the version nibble 7 and the RFC-4122 variant, and
// (b) a validator that verifies the version nibble AND the variant bits so a v4 / garbage body
// is REJECTED. Canon: repo-root conventions "IDs: UUID v7", DOKANDAR-Domain-Model type rules.

namespace Dkd.Platform;

using System.Security.Cryptography;

/// <summary>
/// UUID version 7 (RFC 9562) generator and validator. Canonical string form is the lowercase
/// 8-4-4-4-12 hyphenated hex layout (36 chars). The 48 most-significant bits carry a big-endian
/// Unix-milliseconds timestamp, making generated ids k-sortable; the remaining bits are random
/// except the version nibble (<c>0x7</c>) and the two variant bits (<c>10</c>).
/// </summary>
public static class Uuid7
{
    private const int ByteLen = 16;
    private const int StrLen = 36;

    /// <summary>Generate a fresh, time-ordered UUID v7 in canonical lowercase-hyphenated form.</summary>
    public static string NewId() => NewId(DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());

    /// <summary>Generate a UUID v7 for an explicit Unix-ms timestamp (deterministic prefix, random tail).</summary>
    public static string NewId(long unixMs)
    {
        Span<byte> b = stackalloc byte[ByteLen];
        RandomNumberGenerator.Fill(b);

        // 48-bit big-endian millisecond timestamp in bytes 0..5.
        b[0] = (byte)((unixMs >> 40) & 0xFF);
        b[1] = (byte)((unixMs >> 32) & 0xFF);
        b[2] = (byte)((unixMs >> 24) & 0xFF);
        b[3] = (byte)((unixMs >> 16) & 0xFF);
        b[4] = (byte)((unixMs >> 8) & 0xFF);
        b[5] = (byte)(unixMs & 0xFF);

        b[6] = (byte)(0x70 | (b[6] & 0x0F)); // version 7 in the high nibble of byte 6
        b[8] = (byte)(0x80 | (b[8] & 0x3F)); // variant 10xx in the high bits of byte 8

        return Format(b);
    }

    /// <summary>
    /// True only for a well-formed UUID whose version nibble is 7 and whose variant bits are
    /// <c>10</c>. A v4 uuid, a wrong-length string, non-hex, or garbage all return false.
    /// </summary>
    public static bool IsValidV7(string? value)
    {
        if (value is null || value.Length != StrLen) return false;
        if (value[8] != '-' || value[13] != '-' || value[18] != '-' || value[23] != '-') return false;
        if (!TryToBytes(value, out var b)) return false;
        var version = (b[6] & 0xF0) >> 4;
        var variant = (b[8] & 0xC0) >> 6; // top two bits
        return version == 7 && variant == 0b10;
    }

    /// <summary>Recover the embedded Unix-ms timestamp; returns -1 when the input is not a valid v7.</summary>
    public static long TimestampMs(string value)
    {
        if (!IsValidV7(value) || !TryToBytes(value, out var b)) return -1;
        long ms = 0;
        for (var i = 0; i < 6; i++) ms = (ms << 8) | b[i];
        return ms;
    }

    private static string Format(ReadOnlySpan<byte> b)
    {
        var hex = Convert.ToHexString(b).ToLowerInvariant(); // 32 chars, no separators
        return string.Create(StrLen, hex, static (dst, src) =>
        {
            src.AsSpan(0, 8).CopyTo(dst);
            dst[8] = '-';
            src.AsSpan(8, 4).CopyTo(dst[9..]);
            dst[13] = '-';
            src.AsSpan(12, 4).CopyTo(dst[14..]);
            dst[18] = '-';
            src.AsSpan(16, 4).CopyTo(dst[19..]);
            dst[23] = '-';
            src.AsSpan(20, 12).CopyTo(dst[24..]);
        });
    }

    private static bool TryToBytes(string value, out byte[] bytes)
    {
        Span<char> hex = stackalloc char[32];
        var j = 0;
        foreach (var c in value)
        {
            if (c == '-') continue;
            if (!Uri.IsHexDigit(c)) { bytes = Array.Empty<byte>(); return false; }
            hex[j++] = c;
        }
        if (j != 32) { bytes = Array.Empty<byte>(); return false; }
        bytes = Convert.FromHexString(hex);
        return true;
    }
}
