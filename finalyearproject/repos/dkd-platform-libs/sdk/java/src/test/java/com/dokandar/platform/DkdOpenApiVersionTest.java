// HAND-AUTHORED test (NOT dkdgen-generated).
// PL-08 conformance: the apidocs OpenAPI version is pinned to 3.1.0 (matches the frozen
// sdk/openapi/dkd-platform.openapi.json), fixing the 3.0.1/3.0.3/3.1 cross-runtime drift.
package com.dokandar.platform;

import io.swagger.v3.oas.models.OpenAPI;
import io.swagger.v3.oas.models.SpecVersion;

import org.junit.jupiter.api.Test;
import static org.junit.jupiter.api.Assertions.*;

class DkdOpenApiVersionTest {

    @Test
    void pinnedVersionConstantIs310() {
        assertEquals("3.1.0", DkdOpenApiVersion.OPENAPI_VERSION);
    }

    @Test
    void customizerPinsTheDocumentTo310() {
        // a stock springdoc OpenAPI defaults to 3.0.1; the customizer must raise it to 3.1.0.
        OpenAPI doc = new OpenAPI();
        assertNotEquals("3.1.0", doc.getOpenapi(), "precondition: springdoc default is not 3.1.0");

        DkdOpenApiVersion.pin(doc);

        assertEquals("3.1.0", doc.getOpenapi());
        assertEquals(SpecVersion.V31, doc.getSpecVersion());
    }

    @Test
    void customizerBeanAppliesThePin() {
        OpenAPI doc = new OpenAPI();
        new DkdOpenApiVersion().dkdOpenApiVersionCustomizer().customise(doc);
        assertEquals("3.1.0", doc.getOpenapi());
    }
}
