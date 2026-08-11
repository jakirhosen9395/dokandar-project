using Microsoft.OpenApi.Any;
using Microsoft.OpenApi.Models;
using Swashbuckle.AspNetCore.SwaggerGen;

namespace Coupon.Swagger;

/// <summary>
/// Documentation-only OpenAPI customization for 07-coupon (API_DOCS_STANDARD.md).
/// Adds servers, tag descriptions, and the shared <c>ErrorEnvelope</c> component to the document.
/// Behaviour-neutral: only affects the generated /openapi.json + Swagger UI.
/// </summary>
public sealed class CouponDocumentFilter : IDocumentFilter
{
    public void Apply(OpenApiDocument doc, DocumentFilterContext context)
    {
        // ---- servers ----
        doc.Servers = new List<OpenApiServer>
        {
            new() { Url = "https://api.dokandar.com.bd", Description = "prod" },
            new() { Url = "http://localhost:10007", Description = "local" },
        };

        // ---- info contact / license ----
        doc.Info.Contact = new OpenApiContact
        {
            Name = "DOKANDAR Platform",
            Url = new Uri("https://dokandar.com.bd"),
            Email = "api@dokandar.com.bd",
        };
        doc.Info.License = new OpenApiLicense { Name = "Proprietary" };

        // ---- tags with descriptions ----
        doc.Tags = new List<OpenApiTag>
        {
            new() { Name = "ops", Description = "Operational / contract surface (/ready /health /data /metrics)." },
            new() { Name = "coupon", Description = "Coupon templates, four-eyes approval lifecycle, festival campaigns, and validate." },
        };

        // ---- shared ErrorEnvelope schema component ----
        // Shape: { "error": { "code": "...", "message": "...", "request_id": "...", "details": {} } }
        doc.Components ??= new OpenApiComponents();
        doc.Components.Schemas ??= new Dictionary<string, OpenApiSchema>();
        doc.Components.Schemas["ErrorEnvelope"] = new OpenApiSchema
        {
            Type = "object",
            Properties = new Dictionary<string, OpenApiSchema>
            {
                ["error"] = new OpenApiSchema
                {
                    Type = "object",
                    Properties = new Dictionary<string, OpenApiSchema>
                    {
                        ["code"] = new OpenApiSchema { Type = "string", Description = "stable machine code (lowercase snake_case)", Example = new OpenApiString("invalid_request") },
                        ["message"] = new OpenApiSchema { Type = "string", Description = "human-readable, scrubbed message", Example = new OpenApiString("code must be 3-40 chars") },
                        ["request_id"] = new OpenApiSchema { Type = "string", Description = "honour-or-mint x-request-id", Example = new OpenApiString("a1b2c3d4e5f6") },
                        ["details"] = new OpenApiSchema { Type = "object", AdditionalPropertiesAllowed = true, Nullable = true },
                    },
                },
            },
        };
    }
}

/// <summary>
/// Documentation-only: attaches the applicable 4xx/5xx responses (all referencing the shared
/// <c>ErrorEnvelope</c> component) and a request-body example to each documented operation.
/// Keyed off the operationId set via <c>.WithName(...)</c>. Behaviour-neutral.
/// </summary>
public sealed class CouponOperationFilter : IOperationFilter
{
    static OpenApiResponse Err(string description) => new()
    {
        Description = description,
        Content = new Dictionary<string, OpenApiMediaType>
        {
            ["application/json"] = new()
            {
                Schema = new OpenApiSchema
                {
                    Reference = new OpenApiReference { Type = ReferenceType.Schema, Id = "ErrorEnvelope" },
                },
            },
        },
    };

    static void AddErr(OpenApiOperation op, string code, string description)
    {
        op.Responses ??= new OpenApiResponses();
        if (!op.Responses.ContainsKey(code)) op.Responses[code] = Err(description);
    }

    static void SetBodyExample(OpenApiOperation op, OpenApiObject example)
    {
        if (op.RequestBody?.Content is null) return;
        if (op.RequestBody.Content.TryGetValue("application/json", out var media))
            media.Example = example;
    }

    public void Apply(OpenApiOperation op, OperationFilterContext context)
    {
        var id = op.OperationId;
        if (string.IsNullOrEmpty(id)) return;

        switch (id)
        {
            case "draftCoupon":
                AddErr(op, "401", "missing_token / invalid_token");
                AddErr(op, "403", "insufficient_role (platform-scope or non-shopkeeper)");
                AddErr(op, "422", "invalid_request (validation_error)");
                AddErr(op, "500", "internal_error");
                SetBodyExample(op, new OpenApiObject
                {
                    ["code"] = new OpenApiString("EID2026"),
                    ["kind"] = new OpenApiString("percent"),
                    ["scope"] = new OpenApiString("shop"),
                    ["funded_by"] = new OpenApiString("shopkeeper"),
                    ["shop_id"] = new OpenApiString("11111111-1111-4111-8111-111111111111"),
                    ["value_percent"] = new OpenApiInteger(15),
                    ["max_discount_minor"] = new OpenApiInteger(50000),
                    ["min_spend_minor"] = new OpenApiInteger(100000),
                    ["valid_from"] = new OpenApiString("2026-06-01T00:00:00Z"),
                    ["valid_until"] = new OpenApiString("2026-06-30T23:59:59Z"),
                    ["max_redemptions"] = new OpenApiInteger(1000),
                    ["max_per_user"] = new OpenApiInteger(1),
                });
                break;

            case "listMyCoupons":
                AddErr(op, "401", "missing_token / invalid_token");
                AddErr(op, "500", "internal_error");
                break;

            case "getCoupon":
                AddErr(op, "401", "missing_token / invalid_token");
                AddErr(op, "404", "not_found (unknown or malformed id)");
                AddErr(op, "500", "internal_error");
                break;

            case "approveCoupon":
                AddErr(op, "401", "missing_token / invalid_token");
                AddErr(op, "403", "insufficient_role");
                AddErr(op, "404", "not_found");
                AddErr(op, "409", "approver_is_drafter / invalid_state");
                AddErr(op, "422", "invalid_request");
                AddErr(op, "500", "internal_error");
                break;

            case "revokeCoupon":
                AddErr(op, "401", "missing_token / invalid_token");
                AddErr(op, "403", "insufficient_role");
                AddErr(op, "404", "not_found");
                AddErr(op, "409", "invalid_state");
                AddErr(op, "500", "internal_error");
                break;

            case "listFestivals":
                AddErr(op, "500", "internal_error");
                break;

            case "createFestival":
                AddErr(op, "401", "missing_token / invalid_token");
                AddErr(op, "403", "insufficient_role (admin required)");
                AddErr(op, "422", "invalid_request (slug or template_kind invalid)");
                AddErr(op, "500", "internal_error");
                SetBodyExample(op, new OpenApiObject
                {
                    ["slug"] = new OpenApiString("eid-ul-fitr-2026"),
                    ["name_bn"] = new OpenApiString("ঈদুল ফিতর ২০২৬"),
                    ["name_en"] = new OpenApiString("Eid ul-Fitr 2026"),
                    ["starts_at"] = new OpenApiString("2026-06-01T00:00:00Z"),
                    ["ends_at"] = new OpenApiString("2026-06-10T23:59:59Z"),
                    ["banner_s3_key"] = new OpenApiString("festivals/eid-2026/banner.webp"),
                    ["template_kind"] = new OpenApiString("percent"),
                    ["template_value_percent"] = new OpenApiInteger(20),
                    ["template_max_discount_minor"] = new OpenApiInteger(50000),
                    ["funded_by_default"] = new OpenApiString("platform"),
                });
                break;

            case "optInFestival":
                AddErr(op, "401", "missing_token / invalid_token");
                AddErr(op, "403", "insufficient_role");
                AddErr(op, "404", "not_found (festival)");
                AddErr(op, "422", "invalid_request");
                AddErr(op, "500", "internal_error");
                SetBodyExample(op, new OpenApiObject
                {
                    ["shop_id"] = new OpenApiString("11111111-1111-4111-8111-111111111111"),
                    ["override_value_percent"] = new OpenApiInteger(25),
                });
                break;

            case "validateCoupon":
                // east-west: reference the internalToken apiKey scheme instead of bearer.
                op.Security = new List<OpenApiSecurityRequirement>
                {
                    new()
                    {
                        [new OpenApiSecurityScheme { Reference = new OpenApiReference { Type = ReferenceType.SecurityScheme, Id = "internalToken" } }] = Array.Empty<string>(),
                    },
                };
                AddErr(op, "401", "unauthorized (x-internal-token missing or invalid)");
                AddErr(op, "500", "internal_error");
                SetBodyExample(op, new OpenApiObject
                {
                    ["code"] = new OpenApiString("EID2026"),
                    ["user_id"] = new OpenApiString("22222222-2222-4222-8222-222222222222"),
                    ["subtotal_minor"] = new OpenApiLong(150000),
                    ["shop_id"] = new OpenApiString("11111111-1111-4111-8111-111111111111"),
                    ["order_id"] = new OpenApiString("33333333-3333-4333-8333-333333333333"),
                });
                break;

            case "getReady":
                AddErr(op, "503", "not_ready (PostgreSQL unreachable)");
                break;

            case "getHealth":
                AddErr(op, "503", "unhealthy (a core dependency is down)");
                break;

            case "getData":
                AddErr(op, "404", "no_snapshot");
                AddErr(op, "500", "snapshot_parse_failed");
                break;
        }
    }
}
