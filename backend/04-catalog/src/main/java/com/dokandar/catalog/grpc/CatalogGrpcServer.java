package com.dokandar.catalog.grpc;

import com.dokandar.catalog.api.ApiException;
import com.dokandar.catalog.grpc.proto.*;
import com.dokandar.catalog.observability.CatalogMetrics;
import com.dokandar.catalog.service.CatalogService;
import com.dokandar.catalog.service.StockService;
import io.grpc.*;
import io.grpc.netty.shaded.io.grpc.netty.NettyServerBuilder;
import io.grpc.stub.StreamObserver;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.context.event.ContextRefreshedEvent;
import org.springframework.context.event.EventListener;
import org.springframework.stereotype.Component;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.security.MessageDigest;
import java.util.List;
import java.util.Map;

/**
 * gRPC server on a dedicated HTTP/2 port (9090, external 20004) — the checkout
 * hot path Cart/Order depend on. Every RPC is gated by a constant-time
 * {@code x-internal-token} compare (§12 — {@link MessageDigest#isEqual},
 * fail-closed on empty; never {@code ==}/{@code equals}).
 */
@Component
public class CatalogGrpcServer extends CatalogGrpc.CatalogImplBase {

    private static final Logger LOG = LoggerFactory.getLogger(CatalogGrpcServer.class);
    private static final Metadata.Key<String> TOKEN_KEY =
        Metadata.Key.of("x-internal-token", Metadata.ASCII_STRING_MARSHALLER);

    private final CatalogService catalog;
    private final StockService stock;
    private final CatalogMetrics metrics;
    private final int port;
    private final boolean enabled;
    private final String expectedToken;
    private Server server;

    public CatalogGrpcServer(CatalogService catalog, StockService stock, CatalogMetrics metrics,
                             @Value("${dokandar.grpc.port:9090}") int port,
                             @Value("${dokandar.grpc.enabled:true}") boolean enabled,
                             @Value("${dokandar.internal.service-token:}") String token,
                             @Value("${dokandar.service.app-env:dev}") String appEnv) {
        this.catalog = catalog; this.stock = stock; this.metrics = metrics;
        this.port = port; this.enabled = enabled; this.expectedToken = token;
        // fail-fast: a blank token boots green but UNAUTHENTICATEs every east-west caller (the #1 fleet landmine)
        if ((token == null || token.isBlank()) && ("stage".equals(appEnv) || "prod".equals(appEnv)))
            throw new IllegalStateException("INTERNAL_SERVICE_TOKEN is empty under APP_ENV=" + appEnv + " (fail-fast)");
    }

    @EventListener(ContextRefreshedEvent.class)
    public synchronized void start() throws IOException {
        if (!enabled || server != null) return;
        server = NettyServerBuilder.forPort(port)
            .addService(ServerInterceptors.intercept(this, new TokenInterceptor(expectedToken)))
            .build()
            .start();
        LOG.info("gRPC server listening on :{}", port);
    }

    @PreDestroy
    public synchronized void stop() { if (server != null) server.shutdown(); }

    // ---- RPCs --------------------------------------------------------------

    @Override
    public void getProduct(GetProductRequest req, StreamObserver<Product> obs) {
        try {
            Map<String, Object> p = catalog.getProduct(req.getProductId());
            obs.onNext(toProto(p));
            obs.onCompleted();
        } catch (ApiException e) {
            obs.onError((e.status == 404 ? Status.NOT_FOUND.withDescription("product not found")
                       : e.status == 400 ? Status.INVALID_ARGUMENT.withDescription(e.getMessage())
                       : Status.INTERNAL).asRuntimeException());
        } catch (Exception e) {
            obs.onError(Status.INTERNAL.withDescription("internal").asRuntimeException());
        }
    }

    @Override
    public void checkStock(CheckStockRequest req, StreamObserver<StockAnswer> obs) {
        try {
            StockService.StockInfo s = stock.checkStock(req.getVariantId(), req.getShopId(), req.getQuantity());
            obs.onNext(StockAnswer.newBuilder()
                .setSufficient(s.sufficient()).setBackorderable(s.backorderable()).setAvailable(s.available()).build());
            obs.onCompleted();
        } catch (ApiException e) {
            obs.onError((e.status == 404 ? Status.NOT_FOUND.withDescription("variant not found") : Status.INTERNAL).asRuntimeException());
        } catch (Exception e) {
            obs.onError(Status.INTERNAL.withDescription("internal").asRuntimeException());
        }
    }

    @Override
    public void reserveStock(ReserveStockRequest req, StreamObserver<ReserveStockAnswer> obs) {
        if (req.getIdempotencyKey() == null || req.getIdempotencyKey().isBlank()) {
            metrics.reserveOutcome("invalid_argument");
            obs.onError(Status.INVALID_ARGUMENT.withDescription("idempotency_key required").asRuntimeException());
            return;
        }
        try {
            StockService.ReserveResult r = stock.reserve(
                req.getIdempotencyKey(), req.getOrderId(), req.getVariantId(), req.getShopId(), req.getQuantity());
            metrics.reserveOutcome(!r.ok() ? r.errorCode() : (r.backordered() ? "backordered" : "ok"));
            obs.onNext(ReserveStockAnswer.newBuilder()
                .setOk(r.ok()).setErrorCode(r.errorCode() == null ? "" : r.errorCode())
                .setReservationId(r.reservationId() == null ? "" : r.reservationId())
                .setBackordered(r.backordered()).build());
            obs.onCompleted();
        } catch (ApiException e) {
            if (e.status == 404) { metrics.reserveOutcome("not_found"); obs.onError(Status.NOT_FOUND.withDescription("variant not found").asRuntimeException()); }
            else { metrics.reserveOutcome("error"); obs.onError(Status.INTERNAL.asRuntimeException()); }
        } catch (Exception e) {
            metrics.reserveOutcome("error");
            obs.onError(Status.INTERNAL.withDescription("internal").asRuntimeException());
        }
    }

    @Override
    public void releaseStock(ReleaseStockRequest req, StreamObserver<ReleaseStockAnswer> obs) {
        try {
            stock.release(req.getReservationId());
            metrics.releaseCounted();
            obs.onNext(ReleaseStockAnswer.newBuilder().setOk(true).build());
            obs.onCompleted();
        } catch (Exception e) {
            obs.onError(Status.INTERNAL.withDescription("internal").asRuntimeException());
        }
    }

    // ---- Map -> proto ------------------------------------------------------

    @SuppressWarnings("unchecked")
    private Product toProto(Map<String, Object> p) {
        Product.Builder b = Product.newBuilder()
            .setId(s(p, "id")).setNameBn(s(p, "name_bn")).setNameEn(s(p, "name_en"))
            .setDescriptionBn(s(p, "description_bn")).setDescriptionEn(s(p, "description_en"))
            .setSharingModel(s(p, "sharing_model")).setListPriceMinor(i(p, "list_price_minor"))
            .setSalePriceMinor(i(p, "sale_price_minor")).setBackorderable(Boolean.TRUE.equals(p.get("backorderable")));
        Object vs = p.get("variants");
        if (vs instanceof List<?> list) {
            for (Object o : list) {
                Map<String, Object> v = (Map<String, Object>) o;
                Variant.Builder vb = Variant.newBuilder()
                    .setId(s(v, "id")).setNameBn(s(v, "name_bn")).setNameEn(s(v, "name_en"))
                    .setListPriceMinor(i(v, "list_price_minor")).setSalePriceMinor(i(v, "sale_price_minor"));
                Object attrs = v.get("attributes");
                if (attrs instanceof Map<?, ?> m)
                    m.forEach((k, val) -> { if (val != null) vb.putAttributes(String.valueOf(k), String.valueOf(val)); });
                b.addVariants(vb.build());
            }
        }
        return b.build();
    }

    private static String s(Map<String, Object> m, String k) { Object v = m.get(k); return v == null ? "" : String.valueOf(v); }
    private static int i(Map<String, Object> m, String k) { Object v = m.get(k); return (v instanceof Number n) ? n.intValue() : 0; }

    // ---- constant-time token gate -----------------------------------------

    static final class TokenInterceptor implements ServerInterceptor {
        private final String expected;
        TokenInterceptor(String e) { this.expected = e; }
        @Override
        public <Req, Resp> ServerCall.Listener<Req> interceptCall(
                ServerCall<Req, Resp> call, Metadata headers, ServerCallHandler<Req, Resp> next) {
            if (!tokenOk(headers.get(TOKEN_KEY), expected)) {
                call.close(Status.UNAUTHENTICATED.withDescription("missing or invalid x-internal-token"), new Metadata());
                return new ServerCall.Listener<>() {};
            }
            return next.startCall(call, headers);
        }
    }

    static boolean tokenOk(String got, String expected) {
        if (expected == null || expected.isBlank()) return false;
        byte[] a = (got == null ? "" : got).getBytes(StandardCharsets.UTF_8);
        byte[] b = expected.getBytes(StandardCharsets.UTF_8);
        return MessageDigest.isEqual(a, b);
    }
}
