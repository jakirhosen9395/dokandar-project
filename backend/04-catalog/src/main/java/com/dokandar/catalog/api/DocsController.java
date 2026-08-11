package com.dokandar.catalog.api;

import io.swagger.v3.oas.annotations.Hidden;
import org.springframework.http.MediaType;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/**
 * Serves the public {@code GET /docs} Swagger UI entry page. springdoc's bundled
 * swagger-ui index.html hard-codes {@code <title>Swagger UI</title>} and this springdoc
 * version does not honour a page-title property, so the fleet-standard browser
 * {@code <title>} ("04-catalog API") is set here via a CDN-hosted swagger-ui page that
 * loads the springdoc-generated {@code /openapi.json}. springdoc's own UI assets remain
 * available under {@code /swagger-ui} (see application.yml). Hidden from the spec itself.
 */
@RestController
public class DocsController {

    private static final String HTML =
        "<!DOCTYPE html><html><head><meta charset=\"utf-8\"><title>04-catalog API</title>"
        + "<link rel=\"stylesheet\" href=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui.css\"></head>"
        + "<body><div id=\"swagger-ui\"></div>"
        + "<script src=\"https://unpkg.com/swagger-ui-dist@5/swagger-ui-bundle.js\"></script>"
        + "<script>window.ui = SwaggerUIBundle({ url: \"/openapi.json\", dom_id: \"#swagger-ui\", "
        + "deepLinking: true, persistAuthorization: true });</script>"
        + "</body></html>";

    @GetMapping("/docs")
    @Hidden
    public ResponseEntity<String> docs() {
        return ResponseEntity.ok()
            .contentType(MediaType.TEXT_HTML)
            .body(HTML);
    }
}
