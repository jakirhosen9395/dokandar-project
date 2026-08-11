package com.dokandar.order.api;

import com.dokandar.order.auth.JwtAuth;
import com.dokandar.order.config.OrderProperties;
import com.dokandar.order.domain.Order;
import com.dokandar.order.domain.OrderLine;
import com.dokandar.order.domain.OrderStatusHistory;
import com.dokandar.order.domain.SubOrder;
import com.dokandar.order.observability.OrderMetrics;
import com.dokandar.order.repo.OrderLineRepository;
import com.dokandar.order.repo.OrderRepository;
import com.dokandar.order.repo.OrderStatusHistoryRepository;
import com.dokandar.order.repo.SubOrderRepository;
import com.dokandar.order.saga.CheckoutWorkflow;
import com.dokandar.order.saga.PlaceOrderInput;
import com.dokandar.order.saga.PlaceOrderResult;
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
import io.temporal.client.WorkflowClient;
import io.temporal.client.WorkflowExecutionAlreadyStarted;
import io.temporal.client.WorkflowException;
import io.temporal.client.WorkflowOptions;
import io.temporal.failure.ApplicationFailure;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.PathVariable;
import org.springframework.web.bind.annotation.PostMapping;
import org.springframework.web.bind.annotation.RequestBody;
import org.springframework.web.bind.annotation.RequestHeader;
import org.springframework.web.bind.annotation.RequestMapping;
import org.springframework.web.bind.annotation.RestController;

import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import java.util.Optional;
import java.util.UUID;

/**
 * The customer + shopkeeper REST surface for orders / sub-orders. The placement path
 * (POST /orders) is the synchronous front door to the Temporal-orchestrated checkout
 * saga; the lifecycle paths (transition / cancel) write the order state machine + a
 * transactional-outbox row directly (no saga). Bearer-verified via {@link JwtAuth};
 * the error envelope + pretty-JSON + bare-404 are supplied by the foundation
 * ({@link GlobalExceptionHandler} / JsonNewlineFilter).
 *
 * <p>The transactional writes live in a SEPARATE bean ({@link OrderWriteService}) so the
 * @Transactional proxy actually applies — calling a @Transactional method on {@code this}
 * would bypass the proxy (no tx → outbox + business row not atomic). Money is integer minor (paisa).
 */
@RestController
@RequestMapping("/api/v1/order")
@SecurityRequirement(name = "bearerJwt")
public class OrderController {

    private static final Logger LOG = LoggerFactory.getLogger(OrderController.class);

    private final WorkflowClient workflowClient;
    private final OrderProperties props;
    private final JwtAuth jwt;
    private final OrderRepository orders;
    private final SubOrderRepository subOrders;
    private final OrderLineRepository orderLines;
    private final OrderStatusHistoryRepository statusHistory;
    private final OrderWriteService writes;
    private final OrderMetrics metrics;

    public OrderController(WorkflowClient workflowClient, OrderProperties props, JwtAuth jwt,
                           OrderRepository orders, SubOrderRepository subOrders,
                           OrderLineRepository orderLines, OrderStatusHistoryRepository statusHistory,
                           OrderWriteService writes, OrderMetrics metrics) {
        this.workflowClient = workflowClient;
        this.props = props;
        this.jwt = jwt;
        this.orders = orders;
        this.subOrders = subOrders;
        this.orderLines = orderLines;
        this.statusHistory = statusHistory;
        this.writes = writes;
        this.metrics = metrics;
    }

    // =========================================================================
    // POST /orders  — checkout placement (Temporal saga front door)
    // =========================================================================
    @PostMapping("/orders")
    @Tag(name = "orders")
    @Operation(operationId = "placeOrder", summary = "Place an order (checkout saga front door)",
        description = "Synchronously starts + awaits the Temporal checkout saga: reserve stock → validate "
                + "coupon → debit wallet → create payment intent, writing one sub-order per shop. The "
                + "`Idempotency-Key` header is mandatory and becomes the Temporal workflowId; replaying it "
                + "returns the original order (200) instead of re-charging. Money is integer minor units (paisa).")
    @ApiResponses({
        @ApiResponse(responseCode = "201", description = "order placed (new)"),
        @ApiResponse(responseCode = "200", description = "idempotent replay — the order already exists for this key"),
        @ApiResponse(responseCode = "400", description = "missing_idempotency_key / validation_error",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "409", description = "placement_in_progress (same key still in flight)",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "422", description = "checkout could not be completed (e.g. stock_changed)",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
    })
    public ResponseEntity<?> placeOrder(
            @Parameter(in = ParameterIn.HEADER, name = "Authorization", description = "Bearer access token",
                example = "Bearer eyJhbGciOiJSUzI1NiIsInR5cCI6IkpXVCJ9...")
            @RequestHeader(value = "Authorization", required = false) String auth,
            @Parameter(in = ParameterIn.HEADER, name = "Idempotency-Key", required = true,
                description = "client-generated unique key (== Temporal workflowId); reusing it returns the original order",
                example = "checkout-2026-06-20-abc123")
            @RequestHeader(value = "Idempotency-Key", required = false) String idemKey,
            @io.swagger.v3.oas.annotations.parameters.RequestBody(required = true, description = "the immutable cart quote",
                content = @Content(mediaType = "application/json", examples = @ExampleObject(value = """
                {
                  "items": [
                    {"shop_id":"22222222-2222-4222-8222-222222222222","product_id":"33333333-3333-4333-8333-333333333333","variant_id":"44444444-4444-4444-8444-444444444444","quantity":2,"unit_price_minor":15000}
                  ],
                  "coupon_code": "EID2026",
                  "payment_method": "cod"
                }""")))
            @RequestBody(required = false) Map<String, Object> body) {
        // 1. Auth FIRST so a no-token request is 401 (not 400 on the missing key).
        JwtAuth.AuthUser user = jwt.verifyOrThrow(auth);

        // 2. Idempotency-Key is mandatory (it is the workflowId / the orders.idempotency_key fence).
        if (idemKey == null || idemKey.isBlank())
            throw new ApiException(400, "missing_idempotency_key", "Idempotency-Key header is required");
        idemKey = idemKey.trim();

        // 3. Build the immutable PlaceOrderInput from the body (customerId = JWT sub).
        PlaceOrderInput input = buildInput(user.id().toString(), idemKey, body);

        // 4. Idempotent replay fast-path: the order already persisted under this key → 200.
        Optional<Order> already = orders.findByIdempotencyKey(idemKey);
        if (already.isPresent())
            return ResponseEntity.status(200).body(toResult(already.get()));

        // 5. Start + await the workflow synchronously (blocks for the placement result).
        CheckoutWorkflow wf = workflowClient.newWorkflowStub(
                CheckoutWorkflow.class,
                WorkflowOptions.newBuilder()
                        .setWorkflowId(idemKey)                       // Idempotency-Key == workflowId
                        .setTaskQueue(props.temporal.taskQueue)       // same value the worker polls
                        .build());
        try {
            PlaceOrderResult r = wf.placeOrder(input);                // blocks; throws on saga failure
            return ResponseEntity.status(201).body(r);
        } catch (WorkflowExecutionAlreadyStarted e) {
            // WorkflowExecutionAlreadyStarted is a subtype of WorkflowException, so it MUST be
            // caught first. Same workflowId already running/completed: re-query the dedup fence.
            // persistOrder runs LAST, so an absent row means the saga is still in flight.
            Optional<Order> existing = orders.findByIdempotencyKey(idemKey);
            if (existing.isPresent())
                return ResponseEntity.status(200).body(toResult(existing.get()));
            throw new ApiException(409, "placement_in_progress",
                    "a checkout with this Idempotency-Key is still being placed");
        } catch (WorkflowException e) {
            // Supertype of WorkflowFailedException — covers saga activity failures (the
            // ApplicationFailure cause carries the business type → 422).
            throw mapSagaFailure(e);
        }
    }

    // =========================================================================
    // GET /orders/me  — the caller's order history (newest first)
    // =========================================================================
    @GetMapping("/orders/me")
    @Tag(name = "orders")
    @Operation(operationId = "listMyOrders", summary = "List my orders (newest first)",
        description = "Returns the authenticated customer's order history (no sub-orders embedded).")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "{ orders: [...] }"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
    })
    public ResponseEntity<?> myOrders(
            @Parameter(in = ParameterIn.HEADER, name = "Authorization", description = "Bearer access token")
            @RequestHeader(value = "Authorization", required = false) String auth) {
        JwtAuth.AuthUser user = jwt.verifyOrThrow(auth);
        List<Map<String, Object>> out = new ArrayList<>();
        for (Order o : orders.findByCustomerIdOrderByCreatedAtDesc(user.id()))
            out.add(orderJson(o, false));
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("orders", out);
        return ResponseEntity.ok(body);
    }

    // =========================================================================
    // GET /orders/{id}  — owner-scoped order + its sub-orders
    // =========================================================================
    @GetMapping("/orders/{id}")
    @Tag(name = "orders")
    @Operation(operationId = "getOrder", summary = "Get an order (owner-scoped, with sub-orders)",
        description = "Returns the order plus its embedded sub-orders. Visible only to the owning customer.")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "order + sub_orders"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "404", description = "order not found / invalid uuid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
    })
    public ResponseEntity<?> getOrder(
            @Parameter(in = ParameterIn.HEADER, name = "Authorization", description = "Bearer access token")
            @RequestHeader(value = "Authorization", required = false) String auth,
            @Parameter(name = "id", description = "order id", required = true,
                schema = @Schema(type = "string", format = "uuid"),
                example = "11111111-1111-4111-8111-111111111111")
            @PathVariable("id") String id) {
        JwtAuth.AuthUser user = jwt.verifyOrThrow(auth);
        Order o = orders.findById(parseUuid(id)).orElseThrow(() -> ApiException.notFound("order not found"));
        if (!o.getCustomerId().equals(user.id()))
            throw ApiException.forbidden("not_owner", "this order belongs to another customer");
        return ResponseEntity.ok(orderJson(o, true));
    }

    // =========================================================================
    // GET /sub-orders/{id}  — sub-order + its status history
    // =========================================================================
    @GetMapping("/sub-orders/{id}")
    @Tag(name = "sub-orders")
    @Operation(operationId = "getSubOrder", summary = "Get a sub-order (with lines + status history)",
        description = "Returns the per-shop sub-order, its order lines, and its status history. Visible to "
                + "the parent order's owner, or to any shopkeeper / admin.")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "sub-order + lines + status_history"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "404", description = "sub-order not found / invalid uuid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
    })
    public ResponseEntity<?> getSubOrder(
            @Parameter(in = ParameterIn.HEADER, name = "Authorization", description = "Bearer access token")
            @RequestHeader(value = "Authorization", required = false) String auth,
            @Parameter(name = "id", description = "sub-order id", required = true,
                schema = @Schema(type = "string", format = "uuid"),
                example = "55555555-5555-4555-8555-555555555555")
            @PathVariable("id") String id) {
        JwtAuth.AuthUser user = jwt.verifyOrThrow(auth);
        SubOrder so = subOrders.findById(parseUuid(id)).orElseThrow(() -> ApiException.notFound("sub-order not found"));
        Order parent = orders.findById(so.getOrderId()).orElseThrow(() -> ApiException.notFound("sub-order not found"));
        // Owner-scoped (the parent order's customer). Shopkeepers/admins read via their own surfaces.
        boolean owner = parent.getCustomerId().equals(user.id());
        boolean staff = "shopkeeper".equals(user.role()) || "admin".equals(user.role());
        if (!owner && !staff)
            throw ApiException.forbidden("not_owner", "this sub-order is not visible to you");
        return ResponseEntity.ok(subOrderJson(so, true));
    }

    // =========================================================================
    // POST /sub-orders/{id}/transition  — role-gated state machine advance
    // =========================================================================
    @PostMapping("/sub-orders/{id}/transition")
    @Tag(name = "sub-orders")
    @Operation(operationId = "transitionSubOrder", summary = "Advance a sub-order's status (shopkeeper/admin)",
        description = "Role-gated state-machine advance. Legal edges: placed→confirmed→packed→"
                + "shipped|ready_for_pickup→delivered|picked_up→completed, plus cancelled (pre-shipped) and "
                + "returned (post-delivery). Writes the new status + a transactional-outbox row.")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "updated sub-order"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "403", description = "insufficient_role (not shopkeeper/admin)",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "404", description = "sub-order not found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "409", description = "invalid_transition",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "422", description = "validation_error (to_status missing)",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
    })
    public ResponseEntity<?> transition(
            @Parameter(in = ParameterIn.HEADER, name = "Authorization", description = "Bearer access token")
            @RequestHeader(value = "Authorization", required = false) String auth,
            @Parameter(name = "id", description = "sub-order id", required = true,
                schema = @Schema(type = "string", format = "uuid"),
                example = "55555555-5555-4555-8555-555555555555")
            @PathVariable("id") String id,
            @io.swagger.v3.oas.annotations.parameters.RequestBody(required = true,
                description = "target status",
                content = @Content(mediaType = "application/json", examples = @ExampleObject(value = """
                {"to_status": "confirmed"}""")))
            @RequestBody(required = false) Map<String, Object> body) {
        JwtAuth.AuthUser user = jwt.verifyOrThrow(auth);
        if (!"shopkeeper".equals(user.role()) && !"admin".equals(user.role()))
            throw ApiException.forbidden("insufficient_role", "only a shopkeeper or admin can transition a sub-order");
        String toStatus = body == null ? null : str(body.get("to_status"));
        if (toStatus == null || toStatus.isBlank())
            throw ApiException.validation("to_status is required");

        SubOrder so = subOrders.findById(parseUuid(id)).orElseThrow(() -> ApiException.notFound("sub-order not found"));
        if (!isLegalTransition(so.getStatus(), toStatus))
            throw new ApiException(409, "invalid_transition",
                    "cannot transition '" + so.getStatus() + "' -> '" + toStatus + "'");

        writes.applyTransition(so.getId(), so.getStatus(), toStatus);
        metrics.transition(toStatus);
        SubOrder fresh = subOrders.findById(so.getId()).orElse(so);
        return ResponseEntity.ok(subOrderJson(fresh, true));
    }

    // =========================================================================
    // POST /sub-orders/{id}/cancel  — cancel if allowed (writes order.cancelled outbox)
    // =========================================================================
    @PostMapping("/sub-orders/{id}/cancel")
    @Tag(name = "sub-orders")
    @Operation(operationId = "cancelSubOrder", summary = "Cancel a sub-order (owner or shopkeeper/admin)",
        description = "Cancels a pre-shipped sub-order, writing an order.cancelled outbox row. Allowed for "
                + "the parent order's owner and for any shopkeeper / admin.")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "cancelled sub-order"),
        @ApiResponse(responseCode = "401", description = "token_missing / token_invalid",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "403", description = "not_owner",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "404", description = "sub-order not found",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "409", description = "invalid_transition (already shipped/terminal)",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
    })
    public ResponseEntity<?> cancel(
            @Parameter(in = ParameterIn.HEADER, name = "Authorization", description = "Bearer access token")
            @RequestHeader(value = "Authorization", required = false) String auth,
            @Parameter(name = "id", description = "sub-order id", required = true,
                schema = @Schema(type = "string", format = "uuid"),
                example = "55555555-5555-4555-8555-555555555555")
            @PathVariable("id") String id) {
        JwtAuth.AuthUser user = jwt.verifyOrThrow(auth);
        SubOrder so = subOrders.findById(parseUuid(id)).orElseThrow(() -> ApiException.notFound("sub-order not found"));
        Order parent = orders.findById(so.getOrderId()).orElseThrow(() -> ApiException.notFound("sub-order not found"));
        boolean owner = parent.getCustomerId().equals(user.id());
        boolean staff = "shopkeeper".equals(user.role()) || "admin".equals(user.role());
        if (!owner && !staff)
            throw ApiException.forbidden("not_owner", "you cannot cancel this sub-order");
        if (!isLegalTransition(so.getStatus(), "cancelled"))
            throw new ApiException(409, "invalid_transition",
                    "cannot cancel a sub-order in status '" + so.getStatus() + "'");

        writes.applyCancel(so.getId(), so.getStatus());
        metrics.transition("cancelled");
        SubOrder fresh = subOrders.findById(so.getId()).orElse(so);
        return ResponseEntity.ok(subOrderJson(fresh, true));
    }

    // =========================================================================
    // helpers
    // =========================================================================

    /** Maps a Temporal saga failure to a 422 with the ApplicationFailure type as the machine code. */
    private ApiException mapSagaFailure(Throwable e) {
        ApplicationFailure af = findApplicationFailure(e);
        if (af != null) {
            String type = af.getType();
            String code = (type == null || type.isBlank()) ? "checkout_failed" : type;   // e.g. stock_changed
            return new ApiException(422, code, "checkout could not be completed: " + code);
        }
        LOG.warn("checkout saga failed with no ApplicationFailure: {}", e.toString());
        return new ApiException(422, "checkout_failed", "checkout could not be completed");
    }

    /** Walk the cause chain for the first io.temporal ApplicationFailure (carries the business type). */
    private static ApplicationFailure findApplicationFailure(Throwable e) {
        for (Throwable t = e; t != null; t = t.getCause()) {
            if (t instanceof ApplicationFailure af) return af;
        }
        return null;
    }

    @SuppressWarnings("unchecked")
    private PlaceOrderInput buildInput(String customerId, String idemKey, Map<String, Object> body) {
        if (body == null) throw ApiException.validation("request body is required");
        Object rawItems = body.get("items");
        if (!(rawItems instanceof List<?> list) || list.isEmpty())
            throw ApiException.validation("items must be a non-empty array");
        List<PlaceOrderInput.Item> items = new ArrayList<>();
        for (Object o : list) {
            if (!(o instanceof Map<?, ?>)) throw ApiException.validation("each item must be an object");
            Map<String, Object> m = (Map<String, Object>) o;
            String shopId = reqStr(m, "shop_id");
            String productId = reqStr(m, "product_id");
            String variantId = reqStr(m, "variant_id");
            int qty = (int) reqLong(m, "quantity");
            long unit = reqLong(m, "unit_price_minor");
            if (qty <= 0) throw ApiException.validation("quantity must be >= 1");
            if (unit < 0) throw ApiException.validation("unit_price_minor must be >= 0");
            items.add(new PlaceOrderInput.Item(shopId, productId, variantId, qty, unit));
        }
        String coupon = str(body.get("coupon_code"));
        String paymentMethod = str(body.get("payment_method"));
        return new PlaceOrderInput(customerId, idemKey, coupon, paymentMethod, items);
    }

    /** Customer-facing order JSON (snake_case, paisa). {@code withSubs} embeds the sub-orders. */
    private Map<String, Object> orderJson(Order o, boolean withSubs) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", o.getId().toString());
        m.put("customer_id", o.getCustomerId().toString());
        m.put("idempotency_key", o.getIdempotencyKey());
        m.put("grand_total_minor", o.getGrandTotalMinor());
        m.put("currency", o.getCurrency());
        m.put("created_at", o.getCreatedAt() == null ? null : o.getCreatedAt().toString());
        if (withSubs) {
            List<Map<String, Object>> subs = new ArrayList<>();
            for (SubOrder so : subOrders.findByOrderId(o.getId())) subs.add(subOrderJson(so, false));
            m.put("sub_orders", subs);
        }
        return m;
    }

    /** Sub-order JSON; {@code withLines} embeds order lines + status history. */
    private Map<String, Object> subOrderJson(SubOrder so, boolean withDetail) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("id", so.getId().toString());
        m.put("order_id", so.getOrderId().toString());
        m.put("shop_id", so.getShopId().toString());
        m.put("status", so.getStatus());
        m.put("payment_state", so.getPaymentState());
        m.put("delivery_method", so.getDeliveryMethod());
        m.put("shop_total_minor", so.getShopTotalMinor());
        m.put("confirmed_at", so.getConfirmedAt() == null ? null : so.getConfirmedAt().toString());
        m.put("created_at", so.getCreatedAt() == null ? null : so.getCreatedAt().toString());
        if (withDetail) {
            List<Map<String, Object>> lines = new ArrayList<>();
            for (OrderLine l : orderLines.findBySubOrderId(so.getId())) {
                Map<String, Object> lm = new LinkedHashMap<>();
                lm.put("id", l.getId().toString());
                lm.put("product_id", l.getProductId().toString());
                lm.put("variant_id", l.getVariantId().toString());
                lm.put("quantity", l.getQuantity());
                lm.put("unit_price_minor", l.getUnitPriceMinor());
                lm.put("sale_price_minor", l.getSalePriceMinor());
                lm.put("line_total_minor", l.getLineTotalMinor());
                lines.add(lm);
            }
            m.put("lines", lines);
            List<Map<String, Object>> hist = new ArrayList<>();
            for (OrderStatusHistory h : statusHistory.findBySubOrderIdOrderByAtAsc(so.getId())) {
                Map<String, Object> hm = new LinkedHashMap<>();
                hm.put("from_status", h.getFromStatus());
                hm.put("to_status", h.getToStatus());
                hm.put("at", h.getAt() == null ? null : h.getAt().toString());
                hist.add(hm);
            }
            m.put("status_history", hist);
        }
        return m;
    }

    private PlaceOrderResult toResult(Order o) {
        List<PlaceOrderResult.SubOrderResult> subs = new ArrayList<>();
        for (SubOrder so : subOrders.findByOrderId(o.getId()))
            subs.add(new PlaceOrderResult.SubOrderResult(
                    so.getId().toString(), so.getShopId().toString(), so.getStatus(), so.getShopTotalMinor()));
        return new PlaceOrderResult(o.getId().toString(), "placed", subs);
    }

    private static UUID parseUuid(String s) {
        try { return UUID.fromString(s); } catch (Exception e) { throw ApiException.badUuid(); }
    }
    private static String str(Object o) { return o == null ? null : String.valueOf(o); }
    private static String reqStr(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v == null || String.valueOf(v).isBlank()) throw ApiException.validation(k + " is required");
        return String.valueOf(v);
    }
    private static long reqLong(Map<String, Object> m, String k) {
        Object v = m.get(k);
        if (v == null) throw ApiException.validation(k + " is required");
        if (v instanceof Number n) return n.longValue();
        try { return Long.parseLong(String.valueOf(v).trim()); }
        catch (Exception e) { throw ApiException.validation(k + " must be an integer"); }
    }

    // ---- the sub-order state machine ---------------------------------------
    // placed → confirmed → packed → shipped|ready_for_pickup → delivered|picked_up → completed,
    // plus cancelled (from any pre-shipped state) and returned (from delivered/picked_up/completed).
    private static boolean isLegalTransition(String from, String to) {
        if (from == null || to == null) return false;
        if (from.equals(to)) return false;
        return switch (from) {
            case "placed"            -> to.equals("confirmed") || to.equals("cancelled");
            case "confirmed"         -> to.equals("packed") || to.equals("cancelled");
            case "packed"            -> to.equals("shipped") || to.equals("ready_for_pickup") || to.equals("cancelled");
            case "shipped"           -> to.equals("delivered") || to.equals("returned");
            case "ready_for_pickup"  -> to.equals("picked_up") || to.equals("cancelled");
            case "delivered"         -> to.equals("completed") || to.equals("returned");
            case "picked_up"         -> to.equals("completed") || to.equals("returned");
            default                  -> false;   // completed / cancelled / returned are terminal
        };
    }
}
