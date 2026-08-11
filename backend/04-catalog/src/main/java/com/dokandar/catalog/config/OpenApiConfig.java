package com.dokandar.catalog.config;

import io.swagger.v3.oas.models.Components;
import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.info.Contact;
import io.swagger.v3.oas.models.info.Info;
import io.swagger.v3.oas.models.info.License;
import io.swagger.v3.oas.models.media.ObjectSchema;
import io.swagger.v3.oas.models.media.Schema;
import io.swagger.v3.oas.models.media.StringSchema;
import io.swagger.v3.oas.models.security.SecurityScheme;
import io.swagger.v3.oas.models.servers.Server;
import io.swagger.v3.oas.models.tags.Tag;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;

import java.util.List;

/**
 * Fleet-canonical OpenAPI: identity in the description, Bearer-JWT scheme; version read
 * dynamically from CODE_VERSION (§16-d). Adds platform-standard info metadata
 * (contact/license/servers), tags-with-descriptions, the shared {@code ErrorEnvelope}
 * component, and the {@code internalToken} apiKey scheme (the gRPC-adjacent internal surface).
 *
 * <p>NOTE: the {@code HTTPBearer} scheme name is retained (the smoke test asserts
 * {@code components.securitySchemes.HTTPBearer.scheme == bearer}); the platform-standard
 * {@code bearerJwt} alias is added alongside it and is what controllers reference.
 */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI catalogOpenApi(
            @Value("${dokandar.service.name:04-catalog}") String svc,
            @Value("${dokandar.service.tenant:cloud}") String tenant,
            @Value("${dokandar.service.app-env:dev}") String env) {
        String codeVersion = readCodeVersion();
        return new OpenAPI()
            .info(new Info()
                .title("DOKANDAR Catalog Service")
                .version(codeVersion)
                .description(description(svc, codeVersion, env, tenant))
                .contact(new Contact()
                    .name("DOKANDAR Platform")
                    .url("https://dokandar.com.bd")
                    .email("api@dokandar.com.bd"))
                .license(new License().name("Proprietary")))
            .servers(List.of(
                new Server().url("https://api.dokandar.com.bd").description("prod"),
                new Server().url("http://localhost:10004").description("local")))
            .tags(List.of(
                new Tag().name("ops").description("Operational / contract surface (/ready /health /data /metrics /openapi.json /docs)"),
                new Tag().name("products").description("Product graph: listings, variants, shop-listing"),
                new Tag().name("categories").description("Category tree (public read) + category creation (admin)"),
                new Tag().name("stock").description("Per-shop variant stock levels (write model)")))
            .components(new Components()
                .addSecuritySchemes("HTTPBearer", new SecurityScheme()
                    .type(SecurityScheme.Type.HTTP).scheme("bearer").bearerFormat("JWT")
                    .description("Paste a JWT access token (without the 'Bearer ' prefix)."))
                .addSecuritySchemes("bearerJwt", new SecurityScheme()
                    .type(SecurityScheme.Type.HTTP).scheme("bearer").bearerFormat("JWT")
                    .description("RS256 Bearer access token from 01-auth. Paste it without the 'Bearer ' prefix."))
                .addSecuritySchemes("internalToken", new SecurityScheme()
                    .type(SecurityScheme.Type.APIKEY).in(SecurityScheme.In.HEADER).name("x-internal-token")
                    .description("Shared INTERNAL_SERVICE_TOKEN for internal/gRPC-adjacent calls (not used on the public REST surface)."))
                .addSchemas("ErrorEnvelope", errorEnvelopeSchema()));
    }

    private static String description(String svc, String codeVersion, String env, String tenant) {
        return "**service_name**: `" + svc + "` &nbsp;|&nbsp; **code_version**: `" + codeVersion + "` &nbsp;|&nbsp; "
             + "**env**: `" + env + "` &nbsp;|&nbsp; **tenant**: `" + tenant + "`\n\n"
             + "### How to test\n"
             + "1. Click **Authorize** and paste a Bearer **access token** from the auth service "
             + "(`POST /api/v1/auth/login/request` → `/login/verify`). Public reads "
             + "(`GET /products`, `/products/{id}`, `/categories/tree`) need no token.\n"
             + "2. Request bodies are pre-filled with working examples. Money is integer **paisa** (e.g. `15000` = ৳150.00).\n"
             + "3. Only `shopkeeper`/`admin` may create/update products & stock; `global`-scope categories are admin-only.";
    }

    /** The single platform error envelope: {@code {error:{code, message, request_id, details}}}. */
    private static Schema<?> errorEnvelopeSchema() {
        Schema<?> error = new ObjectSchema()
            .addProperty("code", new StringSchema().example("validation_error")
                .description("stable machine code, lowercase snake_case"))
            .addProperty("message", new StringSchema().example("invalid request body"))
            .addProperty("request_id", new StringSchema().example("a1b2c3d4-0000-4000-8000-000000000000"))
            .addProperty("details", new ObjectSchema().description("optional structured detail").nullable(true));
        return new ObjectSchema().addProperty("error", error);
    }

    static String readCodeVersion() {
        try { return java.nio.file.Files.readString(java.nio.file.Path.of("CODE_VERSION")).trim(); }
        catch (Exception e) { return "04-catalog"; }
    }
}
