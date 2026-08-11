// HAND-AUTHORED platform primitive (NOT dkdgen-generated).
// PL-08 — pin the apidocs OpenAPI version to 3.1.0 across the SDK (source-of-truth
// sdk/openapi/dkd-platform.openapi.json is "3.1.0"; springdoc's default emits 3.0.1, which drove
// the 3.0.1/3.0.3/3.1 cross-runtime drift). A springdoc OpenApiCustomizer pins the emitted
// document's spec version to 3.1.0 without touching the generated DkdApiDocs bean.
package com.dokandar.platform;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.SpecVersion;
import org.springdoc.core.customizers.OpenApiCustomizer;
import org.springframework.boot.autoconfigure.AutoConfiguration;
import org.springframework.boot.autoconfigure.condition.ConditionalOnClass;
import org.springframework.context.annotation.Bean;

/**
 * Pins the platform OpenAPI document to 3.1.0. Registered as an auto-configuration so every
 * service inherits the pin with no code; the {@link OpenApiCustomizer} bean is applied by springdoc
 * to the {@code DkdApiDocs} document before it is served, aligning the emitted version with the
 * frozen {@code dkd-platform.openapi.json} (3.1.0) and eliminating the cross-runtime drift.
 */
@AutoConfiguration
@ConditionalOnClass(OpenApiCustomizer.class)
public class DkdOpenApiVersion {

    /** The single OpenAPI version every DOKANDAR apidocs helper emits. */
    public static final String OPENAPI_VERSION = "3.1.0";

    @Bean
    public OpenApiCustomizer dkdOpenApiVersionCustomizer() {
        return DkdOpenApiVersion::pin;
    }

    /** Pin {@code openApi} to OpenAPI 3.1.0 (spec version V31 + version string). Returns it for chaining. */
    public static OpenAPI pin(OpenAPI openApi) {
        return openApi.specVersion(SpecVersion.V31).openapi(OPENAPI_VERSION);
    }
}
