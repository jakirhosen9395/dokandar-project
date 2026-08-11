package com.dokandar.order.saga;

import com.dokandar.order.config.OrderProperties;
import com.dokandar.order.domain.Order;
import com.dokandar.order.domain.OrderLine;
import com.dokandar.order.domain.OrderStatusHistory;
import com.dokandar.order.domain.OutboxEvent;
import com.dokandar.order.domain.SubOrder;
import com.dokandar.order.grpc.clients.CatalogClient;
import com.dokandar.order.grpc.clients.CouponClient;
import com.dokandar.order.grpc.clients.PaymentClient;
import com.dokandar.order.grpc.clients.WalletClient;
import com.dokandar.order.observability.OrderMetrics;
import com.dokandar.order.repo.OrderLineRepository;
import com.dokandar.order.repo.OrderRepository;
import com.dokandar.order.repo.OrderStatusHistoryRepository;
import com.dokandar.order.repo.OutboxRepository;
import com.dokandar.order.repo.SubOrderRepository;
import com.fasterxml.jackson.databind.ObjectMapper;
import com.fasterxml.jackson.databind.node.ArrayNode;
import com.fasterxml.jackson.databind.node.ObjectNode;
import co.elastic.apm.api.CaptureTransaction;
import io.temporal.failure.ApplicationFailure;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;
import org.springframework.transaction.annotation.Transactional;

import java.time.OffsetDateTime;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * Saga side-effects as Spring beans — they hold the gRPC clients, the payment REST
 * client, the JPA repositories, and the outbox writer. Registered on the Temporal worker
 * as an INSTANCE (so DI is wired); the workflow type is registered separately.
 *
 * <p>All deterministic idempotency keys derive from {@code input.idempotencyKey} (a
 * workflow-stable value) — never {@code UUID.randomUUID()} inside an activity, which
 * would break effectively-once on retry. The order's real DB UUID does not exist until
 * {@link #persistOrder} runs last, so the {@code orderId} correlation passed to the
 * peers is the idempotency key (all three peers take it as an opaque String).
 */
@Component
public class CheckoutActivitiesImpl implements CheckoutActivities {

    private static final Logger log = LoggerFactory.getLogger(CheckoutActivitiesImpl.class);
    private static final ObjectMapper MAPPER = new ObjectMapper();

    private final CatalogClient catalog;
    private final CouponClient coupon;
    private final WalletClient wallet;
    private final PaymentClient payment;

    private final OrderRepository orders;
    private final SubOrderRepository subOrders;
    private final OrderLineRepository orderLines;
    private final OrderStatusHistoryRepository statusHistory;
    private final OutboxRepository outbox;

    private final OrderProperties props;
    private final OrderMetrics metrics;

    public CheckoutActivitiesImpl(CatalogClient catalog, CouponClient coupon, WalletClient wallet,
                                  PaymentClient payment, OrderRepository orders, SubOrderRepository subOrders,
                                  OrderLineRepository orderLines, OrderStatusHistoryRepository statusHistory,
                                  OutboxRepository outbox, OrderProperties props, OrderMetrics metrics) {
        this.catalog = catalog;
        this.coupon = coupon;
        this.wallet = wallet;
        this.payment = payment;
        this.orders = orders;
        this.subOrders = subOrders;
        this.orderLines = orderLines;
        this.statusHistory = statusHistory;
        this.outbox = outbox;
        this.props = props;
        this.metrics = metrics;
    }

    // ---- forward + compensation legs --------------------------------------

    // Peers that persist the order correlation (catalog stock_reservations.order_id, payment
    // intents) type it as UUID, but the order's correlation is the opaque client idempotency key.
    // Derive a STABLE UUID from it (deterministic ⇒ effectively-once preserved across retries) so
    // those ::uuid casts don't throw (was surfacing as catalog INTERNAL + payment 500).
    private static String deriveOrderRef(String idempotencyKey) {
        return UUID.nameUUIDFromBytes(idempotencyKey.getBytes(java.nio.charset.StandardCharsets.UTF_8)).toString();
    }

    @Override
    @CaptureTransaction
    public List<String> reserveAll(PlaceOrderInput input) {
        String corr = input.getIdempotencyKey();
        String orderRef = deriveOrderRef(corr);
        List<PlaceOrderInput.Item> items = input.getItems();
        List<String> reserved = new ArrayList<>();
        for (int i = 0; i < items.size(); i++) {
            PlaceOrderInput.Item it = items.get(i);
            String idemKey = corr + ":reserve:" + i;
            try {
                CatalogClient.ReserveResult r = catalog.reserveStock(
                        idemKey, orderRef, it.getVariantId(), it.getShopId(), it.getQuantity());
                reserved.add(r.reservationId());
            } catch (CatalogClient.CatalogStockException e) {
                // Partial-reservation leak guard: release what we already reserved in THIS
                // call before aborting (the saga's releaseAll compensation isn't registered yet).
                releaseQuietly(reserved);
                metrics.sagaOutcome("stock_changed");
                boolean transport = "catalog_unavailable".equals(e.getCode());
                String msg = "stock reservation failed: " + e.getCode();
                // Genuine stock rejection → non-retryable (don't burn the 3 retries); a
                // transport blip stays retryable so a flaky peer recovers within budget.
                throw transport
                        ? ApplicationFailure.newFailureWithCause(msg, "stock_changed", e, e.getCode())
                        : ApplicationFailure.newNonRetryableFailureWithCause(msg, "stock_changed", e, e.getCode());
            }
        }
        return reserved;
    }

    @Override
    @CaptureTransaction
    public void releaseAll(List<String> reservationIds) {
        if (reservationIds == null) return;
        for (String id : reservationIds) {
            if (id == null || id.isBlank()) continue;
            catalog.releaseStock(id);   // throws on transport error → activity retried (no inventory leak)
        }
    }

    @Override
    @CaptureTransaction
    public long applyCoupon(PlaceOrderInput input) {
        long subtotal = 0L;
        String shopId = null;
        for (PlaceOrderInput.Item it : input.getItems()) {
            subtotal += it.getUnitPriceMinor() * (long) it.getQuantity();
            if (shopId == null) shopId = it.getShopId();
        }
        CouponClient.CouponResult r = coupon.validateCoupon(
                input.getCouponCode(), input.getCustomerId(), shopId, subtotal, input.getPaymentMethod());
        return r.valid() ? r.discountMinor() : 0L;
    }

    @Override
    @CaptureTransaction
    public String debit(PlaceOrderInput input, long totalMinor) {
        if (totalMinor <= 0L) return "";   // COD with full coupon cover / zero payable — no ledger move
        String idemKey = input.getIdempotencyKey() + ":debit";
        WalletClient.WalletResult r = wallet.debitWallet(
                input.getCustomerId(), totalMinor, idemKey, input.getIdempotencyKey(), "order_payment");
        return r.entryId();
    }

    @Override
    @CaptureTransaction
    public void credit(PlaceOrderInput input, long amountMinor) {
        if (amountMinor <= 0L) return;
        String idemKey = input.getIdempotencyKey() + ":credit-comp";   // DISTINCT from the debit key
        wallet.creditWallet(input.getCustomerId(), amountMinor, idemKey,
                input.getIdempotencyKey(), "refund_to_wallet");
    }

    @Override
    @CaptureTransaction
    public String createPayment(PlaceOrderInput input, Map<String, Long> perShopMinor) {
        String state = "pending";
        for (Map.Entry<String, Long> e : perShopMinor.entrySet()) {
            PaymentClient.PaymentIntent intent = payment.createIntent(
                    deriveOrderRef(input.getIdempotencyKey()), input.getCustomerId(), e.getKey(), e.getValue(), "BDT");
            // sub_orders.payment_state CHECK allows only pending|settled|failed|refunded, but the
            // provider reports its own fresh-intent states (e.g. COD "cod_pending") → map them to
            // "pending" so persistOrder doesn't violate the constraint (was a 422 at the last saga step).
            String s = intent.state();
            if ("settled".equals(s) || "failed".equals(s) || "refunded".equals(s)) state = s;
        }
        return state;
    }

    // ---- the single-transaction persist -----------------------------------

    @Override
    @CaptureTransaction
    @Transactional
    public PlaceOrderResult persistOrder(PlaceOrderInput input, long discountMinor,
                                         List<String> reservationIds, String paymentState) {
        // Idempotent: a retried placement with the same idempotency_key returns the existing order.
        Optional<Order> existing = orders.findByIdempotencyKey(input.getIdempotencyKey());
        if (existing.isPresent()) {
            return toResult(existing.get());
        }

        OffsetDateTime now = OffsetDateTime.now();
        UUID customerId = UUID.fromString(input.getCustomerId());

        // Per-shop split (insertion-ordered) + totals.
        Map<String, List<PlaceOrderInput.Item>> byShop = new LinkedHashMap<>();
        for (PlaceOrderInput.Item it : input.getItems()) {
            byShop.computeIfAbsent(it.getShopId(), k -> new ArrayList<>()).add(it);
        }
        long subtotalMinor = 0L;
        for (PlaceOrderInput.Item it : input.getItems()) {
            subtotalMinor += it.getUnitPriceMinor() * (long) it.getQuantity();
        }
        long grandTotalMinor = Math.max(0L, subtotalMinor - discountMinor);

        Order order = new Order();
        order.setCustomerId(customerId);
        order.setIdempotencyKey(input.getIdempotencyKey());
        order.setGrandTotalMinor((int) grandTotalMinor);   // paisa fits int under the 50k BDT cap
        order.setCurrency("BDT");
        order.setCreatedAt(now);
        Order savedOrder = orders.save(order);   // UUID generated here

        List<PlaceOrderResult.SubOrderResult> subResults = new ArrayList<>();
        ArrayNode subOrdersJson = MAPPER.createArrayNode();

        for (Map.Entry<String, List<PlaceOrderInput.Item>> e : byShop.entrySet()) {
            long shopTotal = 0L;
            for (PlaceOrderInput.Item it : e.getValue()) {
                shopTotal += it.getUnitPriceMinor() * (long) it.getQuantity();
            }
            SubOrder sub = new SubOrder();
            sub.setOrderId(savedOrder.getId());
            sub.setShopId(UUID.fromString(e.getKey()));
            sub.setStatus("placed");
            sub.setPaymentState(paymentState == null || paymentState.isBlank() ? "pending" : paymentState);
            sub.setDeliveryMethod("delivery");
            sub.setShopTotalMinor((int) shopTotal);
            sub.setCreatedAt(now);
            SubOrder savedSub = subOrders.save(sub);

            for (PlaceOrderInput.Item it : e.getValue()) {
                OrderLine line = new OrderLine();
                line.setSubOrderId(savedSub.getId());
                line.setProductId(UUID.fromString(it.getProductId()));
                line.setVariantId(UUID.fromString(it.getVariantId()));
                line.setQuantity(it.getQuantity());
                line.setUnitPriceMinor((int) it.getUnitPriceMinor());
                line.setLineTotalMinor((int) (it.getUnitPriceMinor() * (long) it.getQuantity()));
                orderLines.save(line);
            }

            OrderStatusHistory hist = new OrderStatusHistory();
            hist.setSubOrderId(savedSub.getId());
            hist.setFromStatus(null);          // initial transition has no prior state
            hist.setToStatus("placed");
            hist.setAt(now);
            statusHistory.save(hist);
            metrics.transition("placed");

            subResults.add(new PlaceOrderResult.SubOrderResult(
                    savedSub.getId().toString(), e.getKey(), "placed", shopTotal));

            ObjectNode sj = subOrdersJson.addObject();
            sj.put("sub_order_id", savedSub.getId().toString());
            sj.put("shop_id", e.getKey());
            sj.put("shop_total_minor", shopTotal);
        }

        // order.placed outbox row — SAME transaction as the business rows.
        ObjectNode payload = MAPPER.createObjectNode();
        payload.put("event", "order.placed");
        payload.put("order_id", savedOrder.getId().toString());
        payload.put("customer_id", input.getCustomerId());
        payload.put("grand_total_minor", grandTotalMinor);
        payload.put("currency", "BDT");
        payload.put("payment_method", input.getPaymentMethod() == null ? "cod" : input.getPaymentMethod());
        payload.put("placed_at", now.toString());
        payload.set("sub_orders", subOrdersJson);

        OutboxEvent ev = new OutboxEvent();
        ev.setTopic(props.topic.orderPlaced);
        ev.setKey(savedOrder.getId().toString());
        ev.setPayload(payload.toString());
        ev.setCreatedAt(now);
        outbox.save(ev);

        metrics.ordersPlaced.increment();
        metrics.sagaOutcome("ok");

        return new PlaceOrderResult(savedOrder.getId().toString(), "placed", subResults);
    }

    // ---- helpers -----------------------------------------------------------

    private void releaseQuietly(List<String> reservationIds) {
        for (String id : reservationIds) {
            if (id == null || id.isBlank()) continue;
            try {
                catalog.releaseStock(id);
            } catch (RuntimeException ex) {
                // best-effort: a leaked reservation is reclaimed by catalog's TTL sweeper.
                log.warn("partial-reservation release failed reservation={}", id, ex);
            }
        }
    }

    private PlaceOrderResult toResult(Order order) {
        List<PlaceOrderResult.SubOrderResult> subs = new ArrayList<>();
        for (SubOrder s : subOrders.findByOrderId(order.getId())) {
            subs.add(new PlaceOrderResult.SubOrderResult(
                    s.getId().toString(), s.getShopId().toString(), s.getStatus(), s.getShopTotalMinor()));
        }
        return new PlaceOrderResult(order.getId().toString(), "placed", subs);
    }
}
