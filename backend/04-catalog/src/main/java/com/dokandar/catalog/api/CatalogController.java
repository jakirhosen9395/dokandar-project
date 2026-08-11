package com.dokandar.catalog.api;

import com.dokandar.catalog.auth.JwtAuth;
import com.dokandar.catalog.service.CatalogService;
import com.dokandar.catalog.service.StockService;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.Parameter;
import io.swagger.v3.oas.annotations.enums.ParameterIn;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.ExampleObject;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.security.SecurityRequirement;
import io.swagger.v3.oas.annotations.tags.Tag;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.*;

import java.util.Map;

@RestController
@RequestMapping("/api/v1/catalog")
@Tag(name = "products", description = "Product graph: listings, variants, shop-listing")
public class CatalogController {

    private final JwtAuth jwt;
    private final CatalogService catalog;
    private final StockService stock;

    public CatalogController(JwtAuth jwt, CatalogService catalog, StockService stock) {
        this.jwt = jwt; this.catalog = catalog; this.stock = stock;
    }

    // shared $ref to the platform ErrorEnvelope component (defined in OpenApiConfig)
    private static final String ERR = "#/components/schemas/ErrorEnvelope";

    // ---- public reads ------------------------------------------------------

    @GetMapping("/products")
    @Operation(operationId = "listProducts", summary = "List products",
        description = "Public read. Returns up to `limit` products. No token required.",
        tags = "products")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "{products:[…]}"),
        @ApiResponse(responseCode = "500", description = "internal_error",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> listProducts(
            @Parameter(in = ParameterIn.QUERY, description = "max rows to return",
                schema = @Schema(type = "integer", defaultValue = "100", minimum = "1", maximum = "500"))
            @RequestParam(value = "limit", required = false, defaultValue = "100") int limit) {
        return ResponseEntity.ok(Map.of("products", catalog.listProducts(limit)));
    }

    @GetMapping("/products/{id}")
    @Operation(operationId = "getProduct", summary = "Get a product by id",
        description = "Public read of a single product (with variants). No token required.",
        tags = "products")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "{product:{…}}"),
        @ApiResponse(responseCode = "404", description = "product_not_found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> getProduct(
            @Parameter(in = ParameterIn.PATH, required = true, description = "product id (UUID)",
                schema = @Schema(type = "string", format = "uuid"),
                example = "11111111-1111-4111-8111-111111111111")
            @PathVariable String id) {
        return ResponseEntity.ok(Map.of("product", catalog.getProduct(id)));
    }

    @GetMapping("/categories/tree")
    @Operation(operationId = "getCategoriesTree", summary = "Category tree",
        description = "Public read of the full category tree. No token required.",
        tags = "categories")
    @ApiResponse(responseCode = "200", description = "{tree:[…]} category hierarchy")
    public ResponseEntity<?> categoriesTree() {
        return ResponseEntity.ok(catalog.categoriesTree());
    }

    // ---- protected writes --------------------------------------------------

    @PostMapping("/products")
    @Operation(operationId = "createProduct", summary = "Create a product",
        description = "Creates a product owned by the caller. Requires `shopkeeper` or `admin` role.",
        tags = "products", security = @SecurityRequirement(name = "bearerJwt"),
        requestBody = @io.swagger.v3.oas.annotations.parameters.RequestBody(required = true,
            content = @Content(mediaType = "application/json",
                examples = @ExampleObject(value = "{\n  \"title\": \"Cotton Panjabi\",\n  \"title_bn\": \"সুতির পাঞ্জাবি\",\n  \"category_id\": \"22222222-2222-4222-8222-222222222222\",\n  \"base_price\": 150000,\n  \"description\": \"Premium cotton, full sleeve\"\n}"))))
    @ApiResponses({
        @ApiResponse(responseCode = "201", description = "created — {product:{…}}"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid / token_expired",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "403", description = "insufficient_role",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "422", description = "validation_error",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> createProduct(@RequestHeader(value = "Authorization", required = false) String bearer,
                                           @RequestBody(required = false) Map<String, Object> body) {
        JwtAuth.AuthUser u = jwt.verifyOrThrow(bearer);
        return ResponseEntity.status(201).body(Map.of("product", catalog.createProduct(u.id(), u.role(), nz(body))));
    }

    @PutMapping("/products/{id}")
    @Operation(operationId = "updateProduct", summary = "Update a product",
        description = "Updates a product owned by the caller (or any product for `admin`).",
        tags = "products", security = @SecurityRequirement(name = "bearerJwt"),
        requestBody = @io.swagger.v3.oas.annotations.parameters.RequestBody(required = true,
            content = @Content(mediaType = "application/json",
                examples = @ExampleObject(value = "{\n  \"title\": \"Cotton Panjabi (updated)\",\n  \"base_price\": 160000\n}"))))
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "updated — {product:{…}}"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "404", description = "product_not_found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "422", description = "validation_error",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> updateProduct(@RequestHeader(value = "Authorization", required = false) String bearer,
                                           @Parameter(in = ParameterIn.PATH, required = true, description = "product id (UUID)",
                                               schema = @Schema(type = "string", format = "uuid"),
                                               example = "11111111-1111-4111-8111-111111111111")
                                           @PathVariable String id, @RequestBody(required = false) Map<String, Object> body) {
        JwtAuth.AuthUser u = jwt.verifyOrThrow(bearer);
        return ResponseEntity.ok(Map.of("product", catalog.updateProduct(id, u.id(), u.role(), nz(body))));
    }

    @DeleteMapping("/products/{id}")
    @Operation(operationId = "deleteProduct", summary = "Delete a product",
        description = "Soft/hard deletes a product owned by the caller (or any for `admin`).",
        tags = "products", security = @SecurityRequirement(name = "bearerJwt"))
    @ApiResponses({
        @ApiResponse(responseCode = "204", description = "deleted (no body)"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "404", description = "product_not_found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> deleteProduct(@RequestHeader(value = "Authorization", required = false) String bearer,
                                           @Parameter(in = ParameterIn.PATH, required = true, description = "product id (UUID)",
                                               schema = @Schema(type = "string", format = "uuid"),
                                               example = "11111111-1111-4111-8111-111111111111")
                                           @PathVariable String id) {
        JwtAuth.AuthUser u = jwt.verifyOrThrow(bearer);
        catalog.deleteProduct(id, u.id(), u.role());
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/products/{id}/variants")
    @Operation(operationId = "addVariant", summary = "Add a product variant",
        description = "Adds a variant (SKU/options/price) to a product owned by the caller.",
        tags = "products", security = @SecurityRequirement(name = "bearerJwt"),
        requestBody = @io.swagger.v3.oas.annotations.parameters.RequestBody(required = true,
            content = @Content(mediaType = "application/json",
                examples = @ExampleObject(value = "{\n  \"sku\": \"PANJABI-RED-L\",\n  \"price\": 155000,\n  \"options\": {\"color\": \"red\", \"size\": \"L\"}\n}"))))
    @ApiResponses({
        @ApiResponse(responseCode = "201", description = "created — {variant:{…}}"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "404", description = "product_not_found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "422", description = "validation_error",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> addVariant(@RequestHeader(value = "Authorization", required = false) String bearer,
                                        @Parameter(in = ParameterIn.PATH, required = true, description = "product id (UUID)",
                                            schema = @Schema(type = "string", format = "uuid"),
                                            example = "11111111-1111-4111-8111-111111111111")
                                        @PathVariable String id, @RequestBody(required = false) Map<String, Object> body) {
        JwtAuth.AuthUser u = jwt.verifyOrThrow(bearer);
        return ResponseEntity.status(201).body(Map.of("variant", catalog.addVariant(id, u.id(), u.role(), nz(body))));
    }

    @DeleteMapping("/products/{id}/variants/{vid}")
    @Operation(operationId = "deleteVariant", summary = "Delete a product variant",
        description = "Removes a variant from a product owned by the caller.",
        tags = "products", security = @SecurityRequirement(name = "bearerJwt"))
    @ApiResponses({
        @ApiResponse(responseCode = "204", description = "deleted (no body)"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "404", description = "product_not_found / variant_not_found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> deleteVariant(@RequestHeader(value = "Authorization", required = false) String bearer,
                                           @Parameter(in = ParameterIn.PATH, required = true, description = "product id (UUID)",
                                               schema = @Schema(type = "string", format = "uuid"),
                                               example = "11111111-1111-4111-8111-111111111111")
                                           @PathVariable String id,
                                           @Parameter(in = ParameterIn.PATH, required = true, description = "variant id (UUID)",
                                               schema = @Schema(type = "string", format = "uuid"),
                                               example = "33333333-3333-4333-8333-333333333333")
                                           @PathVariable String vid) {
        JwtAuth.AuthUser u = jwt.verifyOrThrow(bearer);
        catalog.deleteVariant(id, vid, u.id(), u.role());
        return ResponseEntity.noContent().build();
    }

    @PostMapping("/products/{id}/list-in-shop")
    @Operation(operationId = "listProductInShop", summary = "List a product in a shop",
        description = "Creates a shop-listing linking an owned product to one of the caller's shops.",
        tags = "products", security = @SecurityRequirement(name = "bearerJwt"),
        requestBody = @io.swagger.v3.oas.annotations.parameters.RequestBody(required = true,
            content = @Content(mediaType = "application/json",
                examples = @ExampleObject(value = "{\n  \"shop_id\": \"44444444-4444-4444-8444-444444444444\"\n}"))))
    @ApiResponses({
        @ApiResponse(responseCode = "201", description = "listed — listing payload"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "404", description = "product_not_found / shop_not_found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "409", description = "already_listed",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "422", description = "validation_error",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> listInShop(@RequestHeader(value = "Authorization", required = false) String bearer,
                                        @Parameter(in = ParameterIn.PATH, required = true, description = "product id (UUID)",
                                            schema = @Schema(type = "string", format = "uuid"),
                                            example = "11111111-1111-4111-8111-111111111111")
                                        @PathVariable String id, @RequestBody(required = false) Map<String, Object> body) {
        JwtAuth.AuthUser u = jwt.verifyOrThrow(bearer);
        String shopId = body == null ? null : str(body.get("shop_id"));
        return ResponseEntity.status(201).body(catalog.listInShop(id, u.id(), u.role(), shopId));
    }

    @PutMapping("/stock/{variant_id}")
    @Operation(operationId = "setStock", summary = "Set variant stock for a shop",
        description = "Sets on-hand quantity and low-stock threshold for a variant in one of the caller's shops. "
                    + "Crossing the threshold downward emits `stock.low`.",
        tags = "stock", security = @SecurityRequirement(name = "bearerJwt"),
        requestBody = @io.swagger.v3.oas.annotations.parameters.RequestBody(required = true,
            content = @Content(mediaType = "application/json",
                examples = @ExampleObject(value = "{\n  \"shop_id\": \"44444444-4444-4444-8444-444444444444\",\n  \"on_hand\": 50,\n  \"low_threshold\": 5\n}"))))
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "updated stock level"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "404", description = "variant_not_found / shop_not_found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "422", description = "validation_error",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> setStock(@RequestHeader(value = "Authorization", required = false) String bearer,
                                      @Parameter(in = ParameterIn.PATH, required = true, description = "variant id (UUID)",
                                          schema = @Schema(type = "string", format = "uuid"),
                                          example = "33333333-3333-4333-8333-333333333333")
                                      @PathVariable("variant_id") String variantId,
                                      @RequestBody(required = false) Map<String, Object> body) {
        JwtAuth.AuthUser u = jwt.verifyOrThrow(bearer);
        Map<String, Object> b = nz(body);
        String shopId = str(b.get("shop_id"));
        Integer onHand = intOrNull(b.get("on_hand"));
        Integer lowThreshold = intOrNull(b.get("low_threshold"));
        return ResponseEntity.ok(stock.setStock(variantId, u.id(), u.role(), shopId, onHand, lowThreshold));
    }

    @PostMapping("/categories")
    @Operation(operationId = "createCategory", summary = "Create a category",
        description = "Creates a catalog category. `global`-scope categories are admin-only; "
                    + "`private` categories may be created by `shopkeeper`.",
        tags = "categories", security = @SecurityRequirement(name = "bearerJwt"),
        requestBody = @io.swagger.v3.oas.annotations.parameters.RequestBody(required = true,
            content = @Content(mediaType = "application/json",
                examples = @ExampleObject(value = "{\n  \"name\": \"Panjabi\",\n  \"name_bn\": \"পাঞ্জাবি\",\n  \"scope\": \"private\",\n  \"parent_id\": null\n}"))))
    @ApiResponses({
        @ApiResponse(responseCode = "201", description = "created — {category:{…}}"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "403", description = "insufficient_role (global scope is admin-only)",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "409", description = "category_duplicate",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "422", description = "validation_error",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> createCategory(@RequestHeader(value = "Authorization", required = false) String bearer,
                                            @RequestBody(required = false) Map<String, Object> body) {
        JwtAuth.AuthUser u = jwt.verifyOrThrow(bearer);
        return ResponseEntity.status(201).body(Map.of("category", catalog.createCategory(u.role(), u.id(), nz(body))));
    }

    private static Map<String, Object> nz(Map<String, Object> m) { return m == null ? Map.of() : m; }
    private static String str(Object o) { return (o instanceof String s) ? s : null; }
    private static Integer intOrNull(Object o) {
        if (o instanceof java.math.BigInteger bi) return bi.bitLength() <= 31 ? bi.intValue() : Integer.MAX_VALUE;
        return (o instanceof Number n) ? n.intValue() : null;
    }
}
