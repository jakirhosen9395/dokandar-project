package com.dokandar.order.config;

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
 * Fleet-canonical OpenAPI metadata: identity block + how-to-test in the description,
 * Bearer-JWT scheme, contact/license/servers, named tags, and a single shared
 * {@code ErrorEnvelope} component referenced by the per-operation {@code @ApiResponse}
 * annotations. version = CODE_VERSION (§16-d) — must equal the identity block + APM
 * service.version + log code_version. Documentation-only; no runtime behaviour changes.
 */
@Configuration
public class OpenApiConfig {

    @Bean
    public OpenAPI orderOpenApi(
            @Value("${dokandar.service.name:13-order}") String svc,
            @Value("${dokandar.service.tenant:cloud}") String tenant,
            @Value("${dokandar.service.app-env:dev}") String env) {
        String codeVersion = CodeVersion.VALUE;

        String description =
            "**service_name**: `" + svc + "` &nbsp;|&nbsp; **code_version**: `" + codeVersion + "` &nbsp;|&nbsp; "
          + "**env_version**: `v1.0.0` &nbsp;|&nbsp; **tenant**: `" + tenant + "` &nbsp;|&nbsp; **env**: `" + env + "`\n\n"
          + "Checkout-saga orchestrator + order / sub-order lifecycle. The placement path "
          + "(`POST /orders`) is the synchronous front door to the Temporal-orchestrated checkout saga; "
          + "the lifecycle paths (transition / cancel) advance the sub-order state machine and write a "
          + "transactional-outbox row. Money is integer minor units (paisa).\n\n"
          + "### How to test\n"
          + "1. Click **Authorize** and paste a Bearer **access token** from the auth service "
          + "(`POST /api/v1/auth/login/request` → `/login/verify`). Every business endpoint requires a token.\n"
          + "2. `POST /orders` additionally requires an **`Idempotency-Key`** header — it is the Temporal "
          + "workflowId and the `orders.idempotency_key` dedup fence. Reusing a key returns the original order (200).\n"
          + "3. Only `shopkeeper` / `admin` may transition a sub-order; cancel is allowed for the order owner "
          + "(and shopkeeper/admin) while the sub-order is pre-shipped.";

        // Shared ErrorEnvelope: { "error": { code, message, request_id, details } }
        Schema<?> errorInner = new ObjectSchema()
            .addProperty("code", new StringSchema().example("validation_error")
                .description("stable lowercase snake_case machine code"))
            .addProperty("message", new StringSchema().example("items must be a non-empty array"))
            .addProperty("request_id", new StringSchema().example("11111111-1111-4111-8111-111111111111"))
            .addProperty("details", new ObjectSchema().description("optional structured context"));
        Schema<?> errorEnvelope = new ObjectSchema()
            .description("Platform error envelope (contract §10).")
            .addProperty("error", errorInner);

        return new OpenAPI()
            .info(new Info()
                .title("DOKANDAR Order Service")
                .version(codeVersion)
                .description(description)
                .contact(new Contact()
                    .name("DOKANDAR Platform")
                    .url("https://dokandar.com.bd")
                    .email("api@dokandar.com.bd"))
                .license(new License().name("Proprietary")))
            .servers(List.of(
                new Server().url("https://api.dokandar.com.bd").description("prod"),
                new Server().url("http://localhost:10013").description("local")))
            .tags(List.of(
                new Tag().name("ops").description("Operational / contract surface (/ready /health /data /metrics)"),
                new Tag().name("orders").description("Order placement (checkout saga) + customer order reads"),
                new Tag().name("sub-orders").description("Per-shop sub-order reads + role-gated state-machine transitions")))
            .components(new Components()
                .addSecuritySchemes("bearerJwt", new SecurityScheme()
                    .type(SecurityScheme.Type.HTTP).scheme("bearer").bearerFormat("JWT")
                    .description("Paste a JWT access token (without the 'Bearer ' prefix)."))
                // HTTPBearer kept as an alias so existing tooling/clients that reference it keep working.
                .addSecuritySchemes("HTTPBearer", new SecurityScheme()
                    .type(SecurityScheme.Type.HTTP).scheme("bearer").bearerFormat("JWT")
                    .description("Alias of bearerJwt."))
                .addSchemas("ErrorEnvelope", errorEnvelope));
    }
}
