package com.dokandar.order.grpc;

import com.dokandar.order.grpc.proto.HasPurchasedRequest;
import com.dokandar.order.grpc.proto.HasPurchasedResponse;
import com.dokandar.order.grpc.proto.OrderGrpc;
import com.dokandar.order.repo.SubOrderRepository;
import io.grpc.Metadata;
import io.grpc.Server;
import io.grpc.ServerCall;
import io.grpc.ServerCallHandler;
import io.grpc.ServerInterceptor;
import io.grpc.ServerInterceptors;
import io.grpc.Status;
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
import java.util.UUID;

/**
 * gRPC server on a dedicated HTTP/2 port (9090, external 20013) — the east-west
 * purchase-verification API ({@code Order.HasPurchased}), called by 08-review to gate
 * verified-purchase reviews. Every RPC is gated by a constant-time {@code x-internal-token}
 * compare ({@link MessageDigest#isEqual}, fail-closed on empty; never {@code ==}/{@code equals}),
 * mirroring 04-catalog's gRPC server. Mismatch → UNAUTHENTICATED (code 16).
 *
 * <p>Lifecycle is identical to catalog: bind on {@link ContextRefreshedEvent}, shut down
 * on {@link PreDestroy}. The gRPC peer is NEVER a {@code /ready} gate (spec §8).
 */
@Component
public class OrderGrpcServer extends OrderGrpc.OrderImplBase {

    private static final Logger LOG = LoggerFactory.getLogger(OrderGrpcServer.class);
    private static final Metadata.Key<String> TOKEN_KEY =
            Metadata.Key.of("x-internal-token", Metadata.ASCII_STRING_MARSHALLER);

    private final SubOrderRepository subOrders;
    private final int port;
    private final boolean enabled;
    private final String expectedToken;
    private Server server;

    public OrderGrpcServer(SubOrderRepository subOrders,
                           @Value("${dokandar.grpc.port:9090}") int port,
                           @Value("${dokandar.grpc.enabled:true}") boolean enabled,
                           @Value("${dokandar.internal.service-token:}") String token,
                           @Value("${dokandar.service.app-env:dev}") String appEnv) {
        this.subOrders = subOrders;
        this.port = port;
        this.enabled = enabled;
        this.expectedToken = token;
        // fail-fast: a blank token boots green but UNAUTHENTICATEs every east-west caller (the #1 fleet landmine)
        if ((token == null || token.isBlank()) && ("stage".equals(appEnv) || "prod".equals(appEnv))) {
            throw new IllegalStateException("INTERNAL_SERVICE_TOKEN is empty under APP_ENV=" + appEnv + " (fail-fast)");
        }
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
    public synchronized void stop() {
        if (server != null) server.shutdown();
    }

    // ---- RPCs --------------------------------------------------------------

    @Override
    public void hasPurchased(HasPurchasedRequest req, StreamObserver<HasPurchasedResponse> obs) {
        UUID customerId;
        UUID productId;
        try {
            customerId = UUID.fromString(req.getUserId());
            productId = UUID.fromString(req.getProductId());
        } catch (IllegalArgumentException e) {
            obs.onError(Status.INVALID_ARGUMENT.withDescription("user_id and product_id must be UUIDs").asRuntimeException());
            return;
        }
        try {
            boolean purchased = subOrders.hasPurchased(customerId, productId);
            obs.onNext(HasPurchasedResponse.newBuilder()
                    .setPurchased(purchased)
                    // No per-sub_order state lookup backs this RPC (the query is a boolean
                    // EXISTS); report a best-effort state rather than invent a repo method.
                    .setSubOrderState(purchased ? "purchased" : "")
                    .build());
            obs.onCompleted();
        } catch (Exception e) {
            LOG.warn("HasPurchased failed user={} product={}", customerId, productId, e);
            obs.onError(Status.INTERNAL.withDescription("internal").asRuntimeException());
        }
    }

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
