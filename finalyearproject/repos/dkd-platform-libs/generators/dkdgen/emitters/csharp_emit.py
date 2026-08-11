"""
dkdgen.emitters.csharp_emit — emits the C# (.NET 8) SDK from the IR (namespace Dkd.Platform).

Mirrors the reference emitters (identical semantics), idiomatic C# 12 / .NET 8 (records, nullable
reference types, no third-party deps except xUnit for tests). Framework-only for contract-deferred data.
"""
from __future__ import annotations
import json
from ..ir import Contracts, CONTEXTS
from .base import Writer, pascal, screaming, const_name

NS = "Dkd.Platform"
SRC = "Dkd.Platform"
TST = "Dkd.Platform.Tests"


def _q(s) -> str:
    return json.dumps(s)


def _file(body: str) -> str:
    return "namespace %s;\n\n%s" % (NS, body)


def emit(c: Contracts, meta: dict, out_dir: str) -> list[str]:
    w = Writer(out_dir, "//", meta)

    # provenance
    w.write("%s/Provenance.cs" % SRC, _file(
        "public static class Provenance\n{\n"
        "    public const string Generator = %s;\n"
        "    public const string GeneratorVersion = %s;\n"
        "    public const string ContractVersion = %s;\n"
        "    public const string BuildTime = %s;\n"
        "    public const string BuildCommit = %s;\n}\n" % (
            _q(meta["generator"]), _q(meta["generator_version"]), _q(meta["contract_version"]),
            _q(meta["build_time"]), _q(meta["build_commit"]))))

    # money / time
    w.write("%s/Money.cs" % SRC, _file('''/// <summary>Money is int64 poisha (DM type conventions). Float/decimal money is impossible by type.</summary>
public readonly record struct Money(long Poisha)
{
    public const long PoishaPerBdt = 100L;
    public static Money OfBdt(long bdt) => new(bdt * PoishaPerBdt);
}

/// <summary>Unix milliseconds, UTC (int64).</summary>
public readonly record struct Timestamp(long EpochMs);
'''))

    # ids
    ids = ["/// <summary>Strongly-typed identifiers (ids.yaml). No raw-string IDs.</summary>",
           "public abstract class PrefixedId",
           "{",
           "    public string Value { get; }",
           "    protected PrefixedId(string value, string prefix)",
           "    {",
           "        if (value is null || !value.StartsWith(prefix) || value.Length <= prefix.Length)",
           "            throw new ArgumentException($\"{GetType().Name} must start with '{prefix}' and carry a body\");",
           "        Value = value;",
           "    }",
           "    public override string ToString() => Value;",
           "    public override bool Equals(object? o) => o is not null && o.GetType() == GetType() && ((PrefixedId)o).Value == Value;",
           "    public override int GetHashCode() => System.HashCode.Combine(GetType(), Value);",
           "}", ""]
    for i in c.identifiers:
        T = pascal(i.id)
        ids += [
            "public sealed class %s : PrefixedId" % T,
            "{",
            "    public const string Prefix = %s;" % _q(i.prefix),
            "    public const int OwnerContext = %d; // %s" % (i.owner_ctx, CONTEXTS[i.owner_ctx]),
            "    public const bool Immutable = %s;" % ("true" if i.immutable else "false"),
            "    public %s(string value) : base(value, Prefix) { }" % T,
            "}", ""]
    w.write("%s/Ids.cs" % SRC, _file("\n".join(ids)))

    # topics
    tp = ["using System.Collections.Generic;", "",
          "/// <summary>Kafka topics + RabbitMQ queues (messaging.yaml). Cross-context = Kafka only (R6).</summary>",
          "public sealed record TopicMeta(string Name, int Producer, string Key, IReadOnlyList<int> Consumers,",
          "                               string Context, string Aggregate, string Event, int Version);", "",
          "public static class KafkaTopics", "{"]
    for t in c.topics:
        tp.append("    public const string %s = %s;" % (const_name(t.name), _q(t.name)))
    tp += ["}", "", "public static class RabbitQueues", "{"]
    for q in c.queues:
        tp.append("    public const string %s = %s;" % (screaming(q.name), _q(q.name)))
    tp += ["}", "", "public static class Topics", "{",
           "    public static readonly IReadOnlyDictionary<string, TopicMeta> Meta = new Dictionary<string, TopicMeta>", "    {"]
    for t in c.topics:
        cons = ", ".join(str(x) for x in t.consumers)
        tp.append("        [%s] = new TopicMeta(%s, %d, %s, new[] { %s }, %s, %s, %s, %d)," % (
            _q(t.name), _q(t.name), t.producer, _q(t.key), cons, _q(t.context), _q(t.aggregate), _q(t.event), t.version))
    tp += ["    };", "",
           "    public static TopicMeta TopicMetaFor(string name) =>",
           "        Meta.TryGetValue(name, out var m) ? m : throw new System.ArgumentException($\"unknown topic: {name}\");",
           "}"]
    w.write("%s/Topics.cs" % SRC, _file("\n".join(tp)))

    # config
    cf = ["/// <summary>Canon-named operational constants (configuration.yaml). Values verbatim from canon.</summary>",
          "public static class Config", "{"]
    for k in c.constants:
        if isinstance(k.value, int) and not isinstance(k.value, bool):
            cf.append("    public const long %s = %dL; // %s - %s" % (screaming(k.id), k.value, k.human, k.scope))
        else:
            cf.append("    public const string %s = %s; // %s" % (screaming(k.id), _q(k.value), k.human))
    cf.append("}")
    w.write("%s/Config.cs" % SRC, _file("\n".join(cf)))

    # enums (const-string classes preserve exact contract values across casing)
    en = ["using System.Collections.Generic;", "",
          "/// <summary>Canonical enum families (glossary.yaml; FR-IDN-310). Values transcribed verbatim.</summary>"]
    for f in c.enum_families:
        if not f.values:
            continue
        T = pascal(f.family)
        en += ["public static class %s" % T, "{"]
        for v in f.values:
            en.append("    public const string %s = %s;" % (pascal(v), _q(v)))
        en.append("    public static readonly IReadOnlyList<string> All = new[] { %s };" %
                  ", ".join(pascal(v) for v in f.values))
        if f.exhaustive is not True:
            en.append("    // NOTE: contract marks this family non-exhaustive (illustrative).")
        en += ["}", ""]
    w.write("%s/Enums.cs" % SRC, _file("\n".join(en)))

    # errors
    slugs = list(c.error_taxonomy.context_slugs)
    er = ["using System;", "using System.Collections.Generic;", "using System.Text.RegularExpressions;", "",
          "/// <summary>Error taxonomy (error-codes.yaml): dokandar.&lt;context&gt;.&lt;category&gt;.&lt;reason&gt; (RFC-7807).",
          "/// Concrete codes are NEEDS-INFO in frozen contracts; builder + slug set + ProblemDetails + typed",
          "/// exceptions only - never a fabricated code list.</summary>",
          "public static class ContextSlug", "{"]
    for s in slugs:
        er.append("    public const string %s = %s;" % (pascal(s), _q(s)))
    er += ["}", "",
           "public static class Errors", "{",
           "    private static readonly HashSet<string> Slugs = new() { %s };" % ", ".join(_q(s) for s in slugs),
           "    private static readonly Regex CodeRe = new(@\"^dokandar\\.([a-z]+)\\.([a-z0-9_]+)\\.([a-z0-9_]+)$\");",
           "",
           "    public static string ErrorCode(string context, string category, string reason)",
           "    {",
           "        var code = $\"dokandar.{context}.{category}.{reason}\";",
           "        if (!Slugs.Contains(context)) throw new ArgumentException($\"unknown context slug: {context}\");",
           "        if (!CodeRe.IsMatch(code)) throw new ArgumentException($\"error code violates taxonomy: {code}\");",
           "        return code;",
           "    }",
           "}", "",
           "public sealed record ProblemDetails(string Type, string Title, int Status, string Code,",
           "                                    string? Detail = null, string? Instance = null, string? TraceId = null);", "",
           "public class DokandarException : Exception",
           "{",
           "    public string Code { get; }",
           "    public int HttpStatus { get; }",
           "    public string? Detail { get; }",
           "    public DokandarException(string code, string message, int httpStatus = 500, string? detail = null) : base(message)",
           "    {",
           "        Code = code; HttpStatus = httpStatus; Detail = detail;",
           "    }",
           "}",
           "public sealed class ValidationException : DokandarException",
           "{ public ValidationException(string code, string message) : base(code, message, 400) { } }",
           "public sealed class BusinessException : DokandarException",
           "{ public BusinessException(string code, string message) : base(code, message, 409) { } }",
           "public sealed class InfrastructureException : DokandarException",
           "{ public InfrastructureException(string code, string message) : base(code, message, 503) { } }"]
    w.write("%s/Errors.cs" % SRC, _file("\n".join(er)))

    # dto
    w.write("%s/Dto.cs" % SRC, _file('''using System.Collections.Generic;

/// <summary>Common DTOs: the {success,data,error,meta} envelope, cursor pagination, trace/audit metadata.</summary>
public sealed record PageMeta(string? NextCursor = null, bool HasMore = false, int Limit = 0);
public sealed record TraceMetadata(string? TraceId = null, string? SpanId = null, string? CorrelationId = null);
public sealed record AuditMetadata(string? ActorDid = null, long OccurredAtMs = 0, string? RequestId = null);
public sealed record Meta(PageMeta? Page = null, TraceMetadata? Trace = null, IReadOnlyDictionary<string, object>? Extra = null);

public sealed record Response<T>(bool Success, T? Data = default, ProblemDetails? Error = null, Meta? Meta = null)
{
    public static Response<T> Ok(T data, Meta? meta = null) => new(true, data, null, meta);
    public static Response<T> Fail(ProblemDetails error, Meta? meta = null) => new(false, default, error, meta);
}

public sealed record Page<T>(IReadOnlyList<T> Items, PageMeta PageInfo);
'''))

    # events
    w.write("%s/Events.cs" % SRC, _file('''/// <summary>Event envelope/base + headers + metadata + topic binding + serializer interface.
/// Per-event PAYLOAD types are FRAMEWORK-ONLY (schema-registry subjects are NEEDS-INFO): EventEnvelope
/// is generic over the payload; concrete payloads bind on Phase-2 contract population.</summary>
public sealed record EventHeaders(string EventId, long OccurredAtMs, int ProducerContext, string PartitionKey,
                                  string? CorrelationId = null, string? TraceId = null, int SchemaVersion = 1);

public sealed record EventMetadata(string Topic, TopicMeta Meta)
{
    public static EventMetadata For(string topic) => new(topic, Topics.TopicMetaFor(topic));
}

public sealed record EventEnvelope<TPayload>(EventHeaders Headers, string Topic, TPayload Payload);

public interface IPayloadSerializer<TPayload>
{
    byte[] Serialize(TPayload payload);
    TPayload Deserialize(byte[] data);
}
'''))

    # schema
    sc = ["using System;", "using System.Collections.Generic;", "",
          "/// <summary>Schema-registry metadata (schema-registry.yaml): subjects + compatibility + version helpers.",
          "/// Per-subject JSON-Schema is NEEDS-INFO; GetSchema throws until populated.</summary>",
          "public enum Compatibility { Backward }", "",
          "public sealed record SubjectInfo(string Subject, string Topic, string Compatibility, string SchemaStatus);", "",
          "public static class Schema", "{",
          "    public static readonly IReadOnlyDictionary<string, SubjectInfo> Subjects = new Dictionary<string, SubjectInfo>", "    {"]
    for s in c.schema_subjects:
        sc.append("        [%s] = new SubjectInfo(%s, %s, %s, %s)," % (
            _q(s.subject), _q(s.subject), _q(s.topic), _q(s.compatibility), _q(s.schema_status)))
    sc += ["    };", "",
           "    public static string SubjectFor(string topic) =>",
           "        Subjects.TryGetValue(topic, out var s) ? s.Subject : throw new ArgumentException($\"no subject for topic: {topic}\");",
           "    public static void GetSchema(string subject) =>",
           "        throw new NotSupportedException($\"schema for {subject} is NEEDS-INFO in frozen contracts (Phase-2 transcription)\");",
           "    public static bool IsCompatible(int newVersion, int oldVersion) => newVersion >= oldVersion;",
           "}"]
    w.write("%s/Schema.cs" % SRC, _file("\n".join(sc)))

    # security
    se = ["using System.Collections.Generic;", "",
          "/// <summary>Security helpers: access principles, JWT claim names, correlation/trace propagation.",
          "/// Role families are the canonical glossary enums (Enums). Permission MATRIX is NEEDS-INFO.</summary>",
          "public static class Security", "{",
          "    public static readonly IReadOnlyDictionary<string, string> Principles = new Dictionary<string, string>", "    {"]
    for p in c.principles:
        se.append("        [%s] = %s," % (_q(p.id), _q(p.rule)))
    se += ["    };", "}", "",
           "public static class JwtClaims", "{",
           "    public const string SubjectDid = \"sub\";",
           "    public const string KycTier = \"kyc_tier\";",
           "    public const string Roles = \"roles\";",
           "    public const string CorrelationId = \"cid\";",
           "}", "",
           "public sealed class CorrelationContext",
           "{",
           "    public string? CorrelationId { get; init; }",
           "    public string? TraceId { get; init; }",
           "    public string? ActorDid { get; init; }",
           "    public IReadOnlyDictionary<string, string> Headers()",
           "    {",
           "        var h = new Dictionary<string, string>();",
           "        if (CorrelationId is not null) h[\"x-correlation-id\"] = CorrelationId;",
           "        if (TraceId is not null) h[\"traceparent\"] = TraceId;",
           "        return h;",
           "    }",
           "}"]
    w.write("%s/Security.cs" % SRC, _file("\n".join(se)))

    # validation
    w.write("%s/Validation.cs" % SRC, _file('''/// <summary>Validation utilities.</summary>
public static class Validation
{
    public static bool ValidateTopic(string name) => Topics.Meta.ContainsKey(name);
    public static Money ValidateMoney(long poisha) => new(poisha);
}
'''))

    # API Documentation Standard helper (docs/api-documentation-standard.md) — single source of the
    # platform's OpenAPI/Swagger behavior so every service inherits identical docs with one call.
    w.write("%s/ApiDocs.cs" % SRC, _file('''using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.OpenApi;

/// <summary>Platform API Documentation Standard helper. Wires OpenAPI + Swagger UI identically for every
/// service: OpenAPI doc "v1", JSON at /swagger/v1/swagger.json, UI at /docs, a Bearer (JWT) security
/// scheme, and unique schema ids. Services call AddDkdApiDocs(title) + UseDkdApiDocs() — no per-service
/// Swagger configuration. The native tool (Swashbuckle) is an implementation detail of this helper.</summary>
public static class ApiDocs
{
    public static IServiceCollection AddDkdApiDocs(this IServiceCollection services, string title)
    {
        services.AddEndpointsApiExplorer();
        services.AddSwaggerGen(c =>
        {
            c.SwaggerDoc("v1", new OpenApiInfo { Title = title, Version = "v1", Description = title + " REST API." });
            c.CustomSchemaIds(t => t.FullName!.Replace("+", "."));   // unique schema ids (avoid collisions)
            c.AddSecurityDefinition("Bearer", new OpenApiSecurityScheme
            {
                Type = SecuritySchemeType.Http,
                Scheme = "bearer",
                BearerFormat = "JWT",
                Description = "JWT bearer token (injected by the API gateway in production).",
            });
        });
        return services;
    }

    public static IApplicationBuilder UseDkdApiDocs(this IApplicationBuilder app)
    {
        app.UseSwagger();                                  // /swagger/v1/swagger.json
        app.UseSwaggerUI(o =>
        {
            o.SwaggerEndpoint("/swagger/v1/swagger.json", "v1");
            o.RoutePrefix = "docs";                        // UI at /docs
        });
        return app;
    }
}
'''))

    # csproj (no banner)
    w.write("%s/Dkd.Platform.csproj" % SRC, '''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <LangVersion>12</LangVersion>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <RootNamespace>Dkd.Platform</RootNamespace>
    <AssemblyName>Dkd.Platform</AssemblyName>
    <Version>%s</Version>
    <GenerateDocumentationFile>false</GenerateDocumentationFile>
    <TreatWarningsAsErrors>false</TreatWarningsAsErrors>
  </PropertyGroup>
  <ItemGroup>
    <!-- API Documentation Standard helper (ApiDocs.cs) uses ASP.NET Core + Swashbuckle. -->
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
    <PackageReference Include="Swashbuckle.AspNetCore" Version="10.2.3" />
  </ItemGroup>
</Project>
''' % meta["contract_version"], with_banner=False)

    # test project + tests (xUnit)
    w.write("%s/Dkd.Platform.Tests.csproj" % TST, '''<Project Sdk="Microsoft.NET.Sdk">
  <PropertyGroup>
    <TargetFramework>net10.0</TargetFramework>
    <Nullable>enable</Nullable>
    <ImplicitUsings>enable</ImplicitUsings>
    <IsPackable>false</IsPackable>
  </PropertyGroup>
  <ItemGroup>
    <!-- The SDK depends on ASP.NET (ApiDocs helper); the test host needs the same shared framework. -->
    <FrameworkReference Include="Microsoft.AspNetCore.App" />
    <PackageReference Include="Microsoft.NET.Test.Sdk" Version="17.12.0" />
    <PackageReference Include="xunit" Version="2.9.2" />
    <PackageReference Include="xunit.runner.visualstudio" Version="2.8.2" />
  </ItemGroup>
  <ItemGroup>
    <ProjectReference Include="../Dkd.Platform/Dkd.Platform.csproj" />
  </ItemGroup>
</Project>
''', with_banner=False)

    w.write("%s/SdkTests.cs" % TST, _file('''using Xunit;

public class SdkTests
{
    [Fact]
    public void ProvenanceVersion() => Assert.Equal(%s, Dkd.Platform.Provenance.ContractVersion);

    [Fact]
    public void IdsTypedAndValidated()
    {
        var d = new DID("did:dokandar:abc");
        Assert.Equal("did:dokandar:abc", d.ToString());
        Assert.True(DID.Immutable);
        Assert.Equal(1, DID.OwnerContext);
        Assert.Throws<System.ArgumentException>(() => new PPID("did:dokandar:x"));
    }

    [Fact]
    public void Topics_59_WithMeta()
    {
        Assert.Equal(59, Dkd.Platform.Topics.Meta.Count);
        Assert.Equal(3, Dkd.Platform.Topics.TopicMetaFor("custody.passport.CustodyInitialized.v1").Producer);
    }

    [Fact]
    public void MoneyIsInt64() => Assert.Equal(5000L, new Money(5000L).Poisha);

    [Fact]
    public void ErrorTaxonomy()
    {
        Assert.Equal("dokandar.finance.idempotency.duplicate_key",
                     Errors.ErrorCode("finance", "idempotency", "duplicate_key"));
        Assert.Throws<System.ArgumentException>(() => Errors.ErrorCode("frobnicate", "x", "y"));
    }
}
''' % _q(meta["contract_version"])))

    return list(w.written)
