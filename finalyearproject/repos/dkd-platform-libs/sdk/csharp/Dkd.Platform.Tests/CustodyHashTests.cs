// HAND-AUTHORED — CustodyHash Spec v2 conformance against the shared golden fixture.

namespace Dkd.Platform;

using System.Collections.Generic;
using Xunit;

public class CustodyHashTests
{
    private static Dictionary<string, object?> GenesisFields() => new()
    {
        ["ppid"] = "PP-01JABCDEF",
        ["gpid"] = "GP-rice-01JABCDEF",
        ["holder"] = "did:dokandar:01JABCDEF",
        ["holderRole"] = "PRODUCER",
        ["quantity"] = 5000L,
        ["unit"] = "kg",
        ["producedAt"] = 1750000000000L,
        ["initializedAt"] = 1750000001000L,
        ["previousHash"] = "",
    };

    [Fact]
    public void Genesis_MatchesGoldenCanonicalAndDigest()
    {
        const string expectedCanonical =
            "{\"gpid\":\"GP-rice-01JABCDEF\",\"holder\":\"did:dokandar:01JABCDEF\","
            + "\"holderRole\":\"PRODUCER\",\"initializedAt\":1750000001000,"
            + "\"ppid\":\"PP-01JABCDEF\",\"previousHash\":\"\","
            + "\"producedAt\":1750000000000,\"quantity\":5000,\"unit\":\"kg\"}";
        const string expectedDigest =
            "ac543fecee75695fb2b1922ea9e0830f4bddb6ef1ad17e80f278d6171cbe0597";

        Assert.Equal(expectedCanonical, CustodyHash.Canonical(GenesisFields()));
        Assert.Equal(expectedDigest, CustodyHash.EventHash(GenesisFields()));
    }

    [Fact]
    public void EventHash_ExcludedUnconditionally()
    {
        var withHash = GenesisFields();
        withHash["eventHash"] = new string('f', 64);
        Assert.Equal(CustodyHash.EventHash(GenesisFields()), CustodyHash.EventHash(withHash));
    }

    [Fact]
    public void NullMembers_Omitted()
    {
        var fields = new Dictionary<string, object?>
        {
            ["ppid"] = "PP-XYZ",
            ["quantity"] = 10L,
            ["previousHash"] = "abc",
            ["optionalNote"] = null,
            ["anotherNull"] = null,
        };
        Assert.Equal("{\"ppid\":\"PP-XYZ\",\"previousHash\":\"abc\",\"quantity\":10}",
            CustodyHash.Canonical(fields));
        Assert.Equal("2038cd01eb03eef9e9885912bce2b9f48bb37cade73e80b540d71c8109555e96",
            CustodyHash.EventHash(fields));
    }

    [Fact]
    public void UnicodeAndControlChars_R5()
    {
        var fields = new Dictionary<string, object?>
        {
            ["ppid"] = "PP-বাংলা",
            ["label"] = "a<b>c&d\"e\\f",
            ["ctrl"] = "line1\nline2\ttab",
            ["emoji"] = "🌾",
            ["previousHash"] = "",
        };
        Assert.Equal("2feda014115b350c68bed4c3f61238c7df0451b3b78ac6087257b902ab7b5c3b",
            CustodyHash.EventHash(fields));
    }

    [Fact]
    public void NestedSortingAndArrays_R3R8R9()
    {
        var fields = new Dictionary<string, object?>
        {
            ["zeta"] = 1L,
            ["alpha"] = new Dictionary<string, object?>
            {
                ["z"] = 3L,
                ["a"] = 2L,
                ["m"] = new Dictionary<string, object?> { ["y"] = 1L, ["b"] = 2L },
            },
            ["list"] = new List<object?>
            {
                3L, 1L, 2L,
                new Dictionary<string, object?> { ["k"] = "v", ["a"] = "z" },
            },
            ["previousHash"] = "",
        };
        Assert.Equal(
            "{\"alpha\":{\"a\":2,\"m\":{\"b\":2,\"y\":1},\"z\":3},"
            + "\"list\":[3,1,2,{\"a\":\"z\",\"k\":\"v\"}],\"previousHash\":\"\",\"zeta\":1}",
            CustodyHash.Canonical(fields));
        Assert.Equal("564f6f344b5a33543985a3314d240f3e6729c8f231076207a0aca6415c1edd53",
            CustodyHash.EventHash(fields));
    }

    [Fact]
    public void IntAndBool_R6R7()
    {
        var fields = new Dictionary<string, object?>
        {
            ["big"] = 9007199254740992L,
            ["neg"] = -42L,
            ["zero"] = 0L,
            ["flagT"] = true,
            ["flagF"] = false,
            ["previousHash"] = "",
        };
        Assert.Equal("e15d636e41dc5b5db42dcb7f1d8455ba6253f41a2bcf12b5893a834da9d505fb",
            CustodyHash.EventHash(fields));
    }

    [Fact]
    public void VerifyEvent_RoundTrips()
    {
        var fields = GenesisFields();
        fields["eventHash"] = CustodyHash.EventHash(fields);
        Assert.True(CustodyHash.VerifyEvent(fields));
    }
}
