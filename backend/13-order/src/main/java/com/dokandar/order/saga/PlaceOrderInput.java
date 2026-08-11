package com.dokandar.order.saga;

import com.fasterxml.jackson.annotation.JsonProperty;

import java.util.ArrayList;
import java.util.List;

/**
 * The immutable checkout command handed to {@link CheckoutWorkflow#placeOrder}. This is
 * a CROSS-AGENT CONTRACT type — the REST controller (agent C) builds it, Temporal's
 * Jackson converter serializes it into workflow history, and the workflow + activities
 * read it back. It is therefore a plain no-arg-constructor POJO with getters/setters
 * (mirrors {@link com.dokandar.order.config.OrderProperties}); records-with-bare-components
 * are avoided so deserialization never depends on {@code -parameters} bytecode.
 *
 * <p>All money is integer minor units (paisa). {@code items} carries the resolved cart
 * quote; each item already names its shop so the saga can split one sub-order per shop.
 */
public class PlaceOrderInput {

    private String customerId;
    private String idempotencyKey;
    private String couponCode;
    private String paymentMethod;
    private List<Item> items = new ArrayList<>();

    public PlaceOrderInput() {}

    public PlaceOrderInput(String customerId, String idempotencyKey, String couponCode,
                           String paymentMethod, List<Item> items) {
        this.customerId = customerId;
        this.idempotencyKey = idempotencyKey;
        this.couponCode = couponCode;
        this.paymentMethod = paymentMethod;
        this.items = items == null ? new ArrayList<>() : items;
    }

    public String getCustomerId() { return customerId; }
    public void setCustomerId(String v) { this.customerId = v; }

    public String getIdempotencyKey() { return idempotencyKey; }
    public void setIdempotencyKey(String v) { this.idempotencyKey = v; }

    public String getCouponCode() { return couponCode; }
    public void setCouponCode(String v) { this.couponCode = v; }

    public String getPaymentMethod() { return paymentMethod; }
    public void setPaymentMethod(String v) { this.paymentMethod = v; }

    public List<Item> getItems() { return items; }
    public void setItems(List<Item> v) { this.items = v == null ? new ArrayList<>() : v; }

    /** One requested cart line. {@code unitPriceMinor} is the resolved unit price (paisa). */
    public static class Item {
        @JsonProperty("shopId")        private String shopId;
        @JsonProperty("productId")     private String productId;
        @JsonProperty("variantId")     private String variantId;
        @JsonProperty("quantity")      private int quantity;
        @JsonProperty("unitPriceMinor") private long unitPriceMinor;

        public Item() {}

        public Item(String shopId, String productId, String variantId, int quantity, long unitPriceMinor) {
            this.shopId = shopId;
            this.productId = productId;
            this.variantId = variantId;
            this.quantity = quantity;
            this.unitPriceMinor = unitPriceMinor;
        }

        public String getShopId() { return shopId; }
        public void setShopId(String v) { this.shopId = v; }

        public String getProductId() { return productId; }
        public void setProductId(String v) { this.productId = v; }

        public String getVariantId() { return variantId; }
        public void setVariantId(String v) { this.variantId = v; }

        public int getQuantity() { return quantity; }
        public void setQuantity(int v) { this.quantity = v; }

        public long getUnitPriceMinor() { return unitPriceMinor; }
        public void setUnitPriceMinor(long v) { this.unitPriceMinor = v; }
    }
}
