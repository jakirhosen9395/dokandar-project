package com.dokandar.catalog.service;

import com.dokandar.catalog.api.ApiException;
import com.dokandar.catalog.domain.*;
import com.dokandar.catalog.observability.CatalogMetrics;
import com.fasterxml.jackson.databind.ObjectMapper;
import jakarta.persistence.EntityManager;
import jakarta.persistence.PersistenceContext;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.data.domain.PageRequest;
import org.springframework.stereotype.Service;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.time.ZoneOffset;
import java.util.*;

/**
 * Catalog write model — product/variant/category/listing CRUD. Every mutation
 * writes the business row(s) and an outbox row in ONE transaction (§10 / §12),
 * with the rich event payloads the Go reference emits. Money is integer minor
 * units; the boundary (controllers) rejects > INT4 before it can overflow.
 */
@Service
public class CatalogService {

    static final int MAX_MINOR = 2147483647;
    private static final Set<String> WRITE_ROLES = Set.of("shopkeeper", "shop_staff", "admin");
    private static final Set<String> UPDATE_KEYS = Set.of(
        "name_bn", "name_en", "description_bn", "description_en", "brand", "sku",
        "category_id", "sharing_model", "list_price_minor", "sale_price_minor", "backorderable", "status");

    private final ProductRepository products;
    private final ProductVariantRepository variants;
    private final ProductCategoryRepository categories;
    private final ProductListingRepository listings;
    private final OutboxRepository outbox;
    private final CatalogMetrics metrics;
    private final ObjectMapper json = new ObjectMapper();

    @PersistenceContext private EntityManager em;

    private final String topicProduct;
    private final String topicCategory;

    public CatalogService(ProductRepository products, ProductVariantRepository variants,
                          ProductCategoryRepository categories, ProductListingRepository listings,
                          OutboxRepository outbox, CatalogMetrics metrics,
                          @Value("${dokandar.topic.product-changed:dokandar.product.changed}") String topicProduct,
                          @Value("${dokandar.topic.category-changed:dokandar.category.changed}") String topicCategory) {
        this.products = products; this.variants = variants; this.categories = categories;
        this.listings = listings; this.outbox = outbox; this.metrics = metrics;
        this.topicProduct = topicProduct; this.topicCategory = topicCategory;
    }

    // ---- products ----------------------------------------------------------

    @Transactional(readOnly = true)
    public List<Map<String, Object>> listProducts(int limit) {
        int n = (limit > 0 && limit <= 100) ? limit : 100;
        return products.findByStatusOrderByCreatedAtDesc("active", PageRequest.of(0, n))
                .stream().map(p -> productMap(p, null)).toList();
    }

    @Transactional(readOnly = true)
    public Map<String, Object> getProduct(String id) {
        UUID pid = parseUuid(id);
        Product p = products.findByIdAndStatusNot(pid, "deleted")
                .orElseThrow(() -> ApiException.notFound("No product with id " + id));
        metrics.productRead();
        return productMap(p, variants.findByProductIdOrderByCreatedAt(pid));
    }

    @Transactional
    public Map<String, Object> createProduct(UUID ownerId, String role, Map<String, Object> body) {
        if (!WRITE_ROLES.contains(role))
            throw ApiException.forbidden("insufficient_role", "Role '" + nz(role) + "' cannot create products.");

        String nameBn = str(body.get("name_bn")), nameEn = str(body.get("name_en"));
        if (isBlank(nameBn) && isBlank(nameEn))
            throw ApiException.validation("name_bn or name_en is required",
                    List.of(Map.of("field", "name_bn", "issue", "at_least_one_required")));
        Long listPrice = asLong(body.get("list_price_minor"));
        if (listPrice == null || listPrice < 0 || listPrice > MAX_MINOR)
            throw ApiException.validation("list_price_minor required (0..2147483647)");
        Long salePrice = asLong(body.get("sale_price_minor"));
        if (salePrice != null && (salePrice < 0 || salePrice > MAX_MINOR))
            throw ApiException.validation("sale_price_minor must be 0..2147483647");
        String sharing = str(body.get("sharing_model"));
        if (isBlank(sharing)) sharing = "shared";
        if (!sharing.equals("shared") && !sharing.equals("per_shop_copy"))
            throw ApiException.validation("sharing_model must be 'shared' or 'per_shop_copy'");

        Product p = new Product();
        p.ownerId = ownerId;
        p.nameBn = nullIfBlank(nameBn); p.nameEn = nullIfBlank(nameEn);
        p.descriptionBn = str(body.get("description_bn")); p.descriptionEn = str(body.get("description_en"));
        p.brand = str(body.get("brand")); p.sku = str(body.get("sku"));
        p.categoryId = uuidOrNull(body.get("category_id"));
        p.sharingModel = sharing;
        p.listPriceMinor = listPrice.intValue();
        p.salePriceMinor = salePrice == null ? null : salePrice.intValue();
        Object back = body.get("backorderable");
        p.backorderable = (back instanceof Boolean b) ? b : true;
        p.status = "draft";
        products.saveAndFlush(p);

        Object listIn = body.get("list_in_shops");
        if (listIn instanceof List<?> shops) {
            for (Object s : shops) {
                // pre-validate the UUID: a non-UUID would raise 22P02 in the native cast and ABORT the whole
                // create transaction (the swallowing catch can't recover an aborted pg tx). Skip invalids cleanly.
                UUID sid = uuidOrNull(s);
                if (sid != null) listings.listInShop(p.id.toString(), sid.toString());
            }
        }
        em.refresh(p);
        emitProductChanged(p, "created");
        metrics.productsCreated.increment();
        return productMap(p, variants.findByProductIdOrderByCreatedAt(p.id));
    }

    @Transactional
    public Map<String, Object> updateProduct(String id, UUID sub, String role, Map<String, Object> body) {
        Product p = ownsOr403(id, sub, role);
        for (Map.Entry<String, Object> e : body.entrySet()) {
            String k = e.getKey();
            if (!UPDATE_KEYS.contains(k)) continue;
            Object v = e.getValue();
            switch (k) {
                case "name_bn" -> p.nameBn = str(v);
                case "name_en" -> p.nameEn = str(v);
                case "description_bn" -> p.descriptionBn = str(v);
                case "description_en" -> p.descriptionEn = str(v);
                case "brand" -> p.brand = str(v);
                case "sku" -> p.sku = str(v);
                case "category_id" -> { if (v instanceof String s && !s.isBlank()) p.categoryId = parseUuid(s); }
                case "sharing_model" -> p.sharingModel = str(v);
                case "status" -> p.status = str(v);
                case "backorderable" -> { if (v instanceof Boolean b) p.backorderable = b; }
                case "list_price_minor", "sale_price_minor" -> {
                    Integer iv = numberOrThrow(k, v);
                    if (k.equals("list_price_minor")) p.listPriceMinor = iv; else p.salePriceMinor = iv;
                }
                default -> { }
            }
        }
        products.saveAndFlush(p);
        em.refresh(p);
        emitProductChanged(p, "updated");
        return productMap(p, variants.findByProductIdOrderByCreatedAt(p.id));
    }

    @Transactional
    public void deleteProduct(String id, UUID sub, String role) {
        Product p = ownsOr403(id, sub, role);
        p.status = "deleted";
        products.saveAndFlush(p);
        emitProductChanged(p, "deleted");
    }

    // ---- variants ----------------------------------------------------------

    @Transactional
    public Map<String, Object> addVariant(String productId, UUID sub, String role, Map<String, Object> body) {
        Product p = ownsOr403(productId, sub, role);
        Long listPrice = asLong(body.get("list_price_minor"));
        if (listPrice == null || listPrice < 0 || listPrice > MAX_MINOR)
            throw ApiException.validation("list_price_minor required (0..2147483647)");
        Long salePrice = asLong(body.get("sale_price_minor"));
        if (salePrice != null && (salePrice < 0 || salePrice > MAX_MINOR))
            throw ApiException.validation("sale_price_minor must be 0..2147483647");

        ProductVariant v = new ProductVariant();
        v.productId = p.id;
        v.nameBn = str(body.get("name_bn")); v.nameEn = str(body.get("name_en"));
        v.attributes = writeAttributes(body.get("attributes"));
        v.listPriceMinor = listPrice.intValue();
        v.salePriceMinor = salePrice == null ? null : salePrice.intValue();
        v.sku = str(body.get("sku"));
        variants.saveAndFlush(v);
        emitProductChanged(p, "updated");
        metrics.variantsCreated.increment();
        return variantMap(v);
    }

    @Transactional
    public void deleteVariant(String productId, String variantId, UUID sub, String role) {
        UUID vid = parseUuid(variantId);
        Product p = ownsOr403(productId, sub, role);
        int n = variants.deleteByIdAndProduct(vid, p.id);
        if (n == 0) throw ApiException.notFound("No such variant");
        emitProductChanged(p, "updated");
    }

    // ---- listings ----------------------------------------------------------

    @Transactional
    public Map<String, Object> listInShop(String productId, UUID sub, String role, String shopId) {
        Product p = ownsOr403(productId, sub, role);
        if (isBlank(shopId)) throw ApiException.validation("shop_id required");
        listings.listInShop(p.id.toString(), shopId);
        emitProductChanged(p, "updated");
        Map<String, Object> out = new LinkedHashMap<>();
        out.put("status", "listed"); out.put("product_id", p.id.toString()); out.put("shop_id", shopId);
        return out;
    }

    // ---- categories --------------------------------------------------------

    @Transactional(readOnly = true)
    public Map<String, Object> categoriesTree() {
        List<ProductCategory> all = categories.findAllByOrderByNameEnAsc();
        Map<UUID, List<ProductCategory>> byParent = new LinkedHashMap<>();
        List<ProductCategory> roots = new ArrayList<>();
        for (ProductCategory c : all) {
            if (c.parentId == null) roots.add(c);
            else byParent.computeIfAbsent(c.parentId, k -> new ArrayList<>()).add(c);
        }
        List<Map<String, Object>> tree = roots.stream().map(c -> categoryNode(c, byParent)).toList();
        return Map.of("tree", tree);
    }

    @Transactional
    public Map<String, Object> createCategory(String role, UUID sub, Map<String, Object> body) {
        if (!Set.of("admin", "shopkeeper", "shop_staff").contains(role))
            throw ApiException.forbidden("forbidden", "Role '" + nz(role) + "' cannot define categories.");
        String nameBn = str(body.get("name_bn")), nameEn = str(body.get("name_en"));
        if (isBlank(nameBn) || isBlank(nameEn))
            throw ApiException.validation("name_bn and name_en required");
        ProductCategory c = new ProductCategory();
        c.nameBn = nameBn; c.nameEn = nameEn;
        c.parentId = uuidOrNull(body.get("parent_id"));
        c.definedBy = role;
        c.ownerId = "admin".equals(role) ? null : sub;
        categories.saveAndFlush(c);
        emitCategoryChanged(c);
        metrics.categoriesCreated.increment();
        return categoryMap(c);
    }

    // ---- helpers: authz, events, mapping -----------------------------------

    private Product ownsOr403(String id, UUID sub, String role) {
        UUID pid = parseUuid(id);
        Product p = products.findById(pid).filter(x -> !"deleted".equals(x.status))
                .orElseThrow(() -> ApiException.notFound("No product with id " + id));
        if (!p.ownerId.equals(sub) && !"admin".equals(role))
            throw ApiException.forbidden("forbidden", "You do not own this product.");
        return p;
    }

    private void emitProductChanged(Product p, String change) {
        String norm = switch (change) { case "created", "deleted" -> change; default -> "updated"; };
        Map<String, Object> e = new LinkedHashMap<>();
        e.put("event", "ProductChanged");
        e.put("product_id", p.id.toString());
        e.put("owner_id", p.ownerId.toString());
        e.put("change", norm);
        e.put("shop_ids", listings.visibleShopIds(p.id.toString()));
        e.put("name_bn", p.nameBn); e.put("name_en", p.nameEn);
        e.put("category_id", p.categoryId == null ? null : p.categoryId.toString());
        e.put("sharing_model", p.sharingModel);
        e.put("list_price_minor", p.listPriceMinor); e.put("sale_price_minor", p.salePriceMinor);
        e.put("at", nowUtc());
        outbox.save(new Outbox(topicProduct, p.id.toString(), toJson(e)));
    }

    private void emitCategoryChanged(ProductCategory c) {
        Map<String, Object> e = new LinkedHashMap<>();
        e.put("event", "CategoryChanged");
        e.put("category_id", c.id.toString());
        e.put("parent_id", c.parentId == null ? null : c.parentId.toString());
        e.put("name_bn", c.nameBn); e.put("name_en", c.nameEn);
        e.put("defined_by", c.definedBy);
        e.put("change", "created");
        e.put("at", nowUtc());
        outbox.save(new Outbox(topicCategory, c.id.toString(), toJson(e)));
    }

    private Map<String, Object> productMap(Product p, List<ProductVariant> vs) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", p.id.toString());
        m.put("owner_id", p.ownerId.toString());
        m.put("name_bn", p.nameBn); m.put("name_en", p.nameEn);
        m.put("description_bn", p.descriptionBn); m.put("description_en", p.descriptionEn);
        m.put("brand", p.brand); m.put("sku", p.sku);
        m.put("category_id", p.categoryId == null ? null : p.categoryId.toString());
        m.put("sharing_model", p.sharingModel);
        m.put("list_price_minor", p.listPriceMinor); m.put("sale_price_minor", p.salePriceMinor);
        m.put("backorderable", p.backorderable);
        m.put("status", p.status);
        m.put("created_at", p.createdAt == null ? null : p.createdAt.toString());
        m.put("updated_at", p.updatedAt == null ? null : p.updatedAt.toString());
        if (vs != null && !vs.isEmpty())
            m.put("variants", vs.stream().map(this::variantMap).toList());
        return m;
    }

    private Map<String, Object> variantMap(ProductVariant v) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", v.id.toString());
        m.put("product_id", v.productId.toString());
        m.put("name_bn", v.nameBn); m.put("name_en", v.nameEn);
        Object attrs = readAttributes(v.attributes);
        if (attrs != null) m.put("attributes", attrs);
        m.put("list_price_minor", v.listPriceMinor); m.put("sale_price_minor", v.salePriceMinor);
        m.put("sku", v.sku);
        return m;
    }

    private Map<String, Object> categoryMap(ProductCategory c) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", c.id.toString());
        m.put("name_bn", c.nameBn); m.put("name_en", c.nameEn);
        m.put("parent_id", c.parentId == null ? null : c.parentId.toString());
        m.put("defined_by", c.definedBy);
        m.put("owner_id", c.ownerId == null ? null : c.ownerId.toString());
        return m;
    }

    private Map<String, Object> categoryNode(ProductCategory c, Map<UUID, List<ProductCategory>> byParent) {
        Map<String, Object> m = categoryMap(c);
        List<ProductCategory> kids = byParent.get(c.id);
        if (kids != null && !kids.isEmpty())
            m.put("children", kids.stream().map(k -> categoryNode(k, byParent)).toList());
        return m;
    }

    // ---- small utils -------------------------------------------------------

    private Integer numberOrThrow(String key, Object v) {
        Long l = asLong(v);
        if (l != null && l >= 0 && l <= MAX_MINOR) return l.intValue();
        throw ApiException.validation(key + " must be a number 0..2147483647");
    }
    private String writeAttributes(Object attrs) {
        if (attrs == null) return null;
        try { return json.writeValueAsString(attrs); } catch (Exception e) { return null; }
    }
    private Object readAttributes(String s) {
        if (s == null || s.isBlank()) return null;
        try { return json.readValue(s, Object.class); } catch (Exception e) { return null; }
    }
    private String toJson(Object o) { try { return json.writeValueAsString(o); } catch (Exception e) { return "{}"; } }
    static UUID parseUuid(String s) { try { return UUID.fromString(s); } catch (Exception e) { throw ApiException.badUuid(); } }
    private static UUID uuidOrNull(Object o) { try { return (o instanceof String s && !s.isBlank()) ? UUID.fromString(s) : null; } catch (Exception e) { return null; } }
    private static String str(Object o) { return (o instanceof String s) ? s : null; }
    /** Overflow-safe numeric read: never truncates a > INT4 value to a wrapped int (so the boundary rejects, never overflows). */
    private static Long asLong(Object o) {
        if (o instanceof java.math.BigInteger bi) return bi.bitLength() <= 62 ? bi.longValue() : Long.MAX_VALUE;
        if (o instanceof Integer || o instanceof Long || o instanceof Short || o instanceof Byte) return ((Number) o).longValue();
        if (o instanceof Number n) return (long) Math.floor(n.doubleValue());
        return null;
    }
    private static boolean isBlank(String s) { return s == null || s.isBlank(); }
    private static String nullIfBlank(String s) { return isBlank(s) ? null : s; }
    private static String nz(String s) { return s == null ? "" : s; }
    static String nowUtc() { return OffsetDateTime.now(ZoneOffset.UTC).toString(); }
}
