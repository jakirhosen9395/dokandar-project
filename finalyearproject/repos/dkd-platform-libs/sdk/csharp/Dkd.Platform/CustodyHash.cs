// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// CustodyHash Specification v2 — DM §2 (RFC-8785 subset R1-R9). One of five byte-identical
// runtime implementations; the shared gate is sdk/testvectors/custodyhash_vectors.json (PL-01).
// Ported to match custody_hash.py / custody_hash.go byte-for-byte.

namespace Dkd.Platform;

using System.Collections;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;

/// <summary>
/// Deterministic canonical-JSON serializer + SHA-256 event-hash for the custody chain.
/// Every value tree is built from: <c>IDictionary&lt;string, object?&gt;</c> (objects),
/// <c>IEnumerable</c> (arrays), <c>string</c>, <c>long</c>/<c>int</c> (R6 int64), <c>bool</c>.
/// </summary>
public static class CustodyHash
{
    // R5 — mandatory control-char escapes (all other controls < 0x20 => \u00xx lowercase-hex).
    private static readonly Dictionary<int, string> CtrlEscapes = new()
    {
        [0x08] = "\\b",
        [0x09] = "\\t",
        [0x0A] = "\\n",
        [0x0C] = "\\f",
        [0x0D] = "\\r",
    };

    /// <summary>Serialize <paramref name="value"/> per CustodyHash Spec v2 rules R1-R9.</summary>
    public static string Canonical(object? value)
    {
        var sb = new StringBuilder();
        Write(sb, value);
        return sb.ToString();
    }

    private static void Write(StringBuilder sb, object? value)
    {
        switch (value)
        {
            case null:
                // R2: null is only ever legal as an omitted object member, never a standalone value.
                throw new ArgumentException(
                    "custody: null forbidden outside omitted object members (R2)");
            case bool b:
                sb.Append(b ? "true" : "false"); // R7 lowercase booleans
                return;
            case string s:
                EncodeString(sb, s); // (must precede IEnumerable — string is IEnumerable)
                return;
            case IDictionary<string, object?> dict:
                WriteObject(sb, dict); // (must precede IEnumerable — IDictionary is IEnumerable)
                return;
            case long l:
                sb.Append(l.ToString(CultureInfo.InvariantCulture)); // R6 plain decimal
                return;
            case int i:
                sb.Append(i.ToString(CultureInfo.InvariantCulture)); // R6 plain decimal
                return;
            case IEnumerable items:
                WriteArray(sb, items); // R8 declaration order, R9 recurse
                return;
            default:
                throw new ArgumentException(
                    $"custody: type {value.GetType().Name} has no canonical encoding");
        }
    }

    private static void WriteObject(StringBuilder sb, IDictionary<string, object?> dict)
    {
        // R2 omit null members; R3 sort remaining keys ascending by UTF-8 byte value.
        var keys = new List<string>();
        foreach (var kv in dict)
        {
            if (kv.Value is not null)
            {
                keys.Add(kv.Key);
            }
        }

        keys.Sort(CompareUtf8Bytes);

        sb.Append('{'); // R4 no whitespace
        for (var idx = 0; idx < keys.Count; idx++)
        {
            if (idx > 0)
            {
                sb.Append(',');
            }

            EncodeString(sb, keys[idx]);
            sb.Append(':');
            Write(sb, dict[keys[idx]]); // R9 recurse
        }

        sb.Append('}');
    }

    private static void WriteArray(StringBuilder sb, IEnumerable items)
    {
        sb.Append('[');
        var first = true;
        foreach (var item in items)
        {
            if (!first)
            {
                sb.Append(',');
            }

            first = false;
            Write(sb, item); // R8 order preserved, R9 recurse
        }

        sb.Append(']');
    }

    // R5 — UTF-8; NO HTML escaping (<, >, & stay literal); NO \uXXXX for code points >= U+0080;
    // only the mandatory escapes (\" \\ \b \t \n \f \r and \u00xx for other controls < 0x20).
    private static void EncodeString(StringBuilder sb, string s)
    {
        sb.Append('"');
        foreach (var ch in s)
        {
            if (ch == '"')
            {
                sb.Append("\\\"");
            }
            else if (ch == '\\')
            {
                sb.Append("\\\\");
            }
            else if (CtrlEscapes.TryGetValue(ch, out var esc))
            {
                sb.Append(esc);
            }
            else if (ch < 0x20)
            {
                sb.Append("\\u").Append(((int)ch).ToString("x4", CultureInfo.InvariantCulture));
            }
            else
            {
                // Literal char (incl. <, >, &, Bangla, and each half of an emoji surrogate pair);
                // final Encoding.UTF8.GetBytes emits correct UTF-8 for the whole StringBuilder.
                sb.Append(ch);
            }
        }

        sb.Append('"');
    }

    // R3 — compare by raw UTF-8 byte value (NOT UTF-16 char ordinal, which diverges for
    // code points that surrogate-pair or that fall outside ASCII).
    private static int CompareUtf8Bytes(string a, string b)
    {
        var ba = Encoding.UTF8.GetBytes(a);
        var bb = Encoding.UTF8.GetBytes(b);
        var n = Math.Min(ba.Length, bb.Length);
        for (var i = 0; i < n; i++)
        {
            if (ba[i] != bb[i])
            {
                return ba[i] - bb[i];
            }
        }

        return ba.Length - bb.Length;
    }

    /// <summary>
    /// lowercase-hex SHA-256 over canonical(fields) with <c>eventHash</c> unconditionally excluded.
    /// <c>previousHash</c>, when the event type carries one, must already be present (incl. genesis "").
    /// </summary>
    public static string EventHash(IReadOnlyDictionary<string, object?> fields)
    {
        var canon = new Dictionary<string, object?>();
        foreach (var kv in fields)
        {
            if (kv.Key != "eventHash")
            {
                canon[kv.Key] = kv.Value;
            }
        }

        var bytes = Encoding.UTF8.GetBytes(Canonical(canon));
        var digest = SHA256.HashData(bytes);
        return Convert.ToHexString(digest).ToLowerInvariant();
    }

    /// <summary>Recompute the hash of a stored payload (with eventHash present) and report a match.</summary>
    public static bool VerifyEvent(IReadOnlyDictionary<string, object?> fields)
    {
        if (!fields.TryGetValue("eventHash", out var recorded)
            || recorded is not string s || s.Length == 0)
        {
            throw new ArgumentException("custody: event has no recorded eventHash");
        }

        return EventHash(fields) == s;
    }
}
