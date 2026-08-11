package com.dokandar.order.saga;

import java.util.ArrayList;
import java.util.List;

/**
 * The synchronous result returned by {@link CheckoutWorkflow#placeOrder} — what the REST
 * controller (agent C) blocks for within the placement budget and serializes to the
 * {@code 201} response. CROSS-AGENT CONTRACT type: plain no-arg-constructor POJO with
 * getters/setters so Temporal's Jackson converter round-trips it deterministically.
 *
 * <p>{@code orderId} is the Hibernate-generated {@code orders.id} (a UUID string), set
 * only after {@code persistOrder} runs. {@code status} is the aggregate placement status
 * ({@code "placed"}). One {@link SubOrderResult} per distinct shop.
 */
public class PlaceOrderResult {

    private String orderId;
    private String status;
    private List<SubOrderResult> subOrders = new ArrayList<>();

    public PlaceOrderResult() {}

    public PlaceOrderResult(String orderId, String status, List<SubOrderResult> subOrders) {
        this.orderId = orderId;
        this.status = status;
        this.subOrders = subOrders == null ? new ArrayList<>() : subOrders;
    }

    public String getOrderId() { return orderId; }
    public void setOrderId(String v) { this.orderId = v; }

    public String getStatus() { return status; }
    public void setStatus(String v) { this.status = v; }

    public List<SubOrderResult> getSubOrders() { return subOrders; }
    public void setSubOrders(List<SubOrderResult> v) { this.subOrders = v == null ? new ArrayList<>() : v; }

    /** One persisted sub-order (per shop). {@code shopTotalMinor} is that shop's total in paisa. */
    public static class SubOrderResult {
        private String subOrderId;
        private String shopId;
        private String status;
        private long shopTotalMinor;

        public SubOrderResult() {}

        public SubOrderResult(String subOrderId, String shopId, String status, long shopTotalMinor) {
            this.subOrderId = subOrderId;
            this.shopId = shopId;
            this.status = status;
            this.shopTotalMinor = shopTotalMinor;
        }

        public String getSubOrderId() { return subOrderId; }
        public void setSubOrderId(String v) { this.subOrderId = v; }

        public String getShopId() { return shopId; }
        public void setShopId(String v) { this.shopId = v; }

        public String getStatus() { return status; }
        public void setStatus(String v) { this.status = v; }

        public long getShopTotalMinor() { return shopTotalMinor; }
        public void setShopTotalMinor(long v) { this.shopTotalMinor = v; }
    }
}
