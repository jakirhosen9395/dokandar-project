package com.dokandar.order.grpc.clients;

import com.dokandar.catalog.grpc.proto.CatalogGrpc;
import com.dokandar.order.config.OrderProperties;
import dokandar.coupon.v1.CouponGrpc;
import dokandar.wallet.v1.WalletGrpc;
import io.grpc.CallOptions;
import io.grpc.Channel;
import io.grpc.ClientCall;
import io.grpc.ClientInterceptor;
import io.grpc.ForwardingClientCall;
import io.grpc.ManagedChannel;
import io.grpc.ManagedChannelBuilder;
import io.grpc.Metadata;
import io.grpc.MethodDescriptor;
import jakarta.annotation.PreDestroy;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.stereotype.Component;

import java.util.ArrayList;
import java.util.List;
import java.util.concurrent.TimeUnit;

/**
 * East-west gRPC channels + blocking stubs for the checkout saga's peers
 * (catalog / coupon / wallet). Each channel is plaintext (internal network, no TLS)
 * and carries a {@link ClientInterceptor} that attaches {@code x-internal-token} —
 * the shared INTERNAL_SERVICE_TOKEN — on every call; a peer compares it const-time
 * and answers UNAUTHENTICATED (code 16) on mismatch.
 *
 * <p>Channels are built at construction from the configured peer addresses. A blank
 * address means "not wired yet" — the stub is still created (forTarget tolerates it)
 * and the typed clients surface the failure at call time, never at boot.
 */
@Component
public class GrpcClients {

    private static final Logger log = LoggerFactory.getLogger(GrpcClients.class);

    private static final Metadata.Key<String> INTERNAL_TOKEN =
            Metadata.Key.of("x-internal-token", Metadata.ASCII_STRING_MARSHALLER);

    private final List<ManagedChannel> channels = new ArrayList<>();

    private final CatalogGrpc.CatalogBlockingStub catalogStub;
    private final CouponGrpc.CouponBlockingStub couponStub;
    private final WalletGrpc.WalletBlockingStub walletStub;

    public GrpcClients(OrderProperties props) {
        ClientInterceptor tokenInterceptor = tokenInterceptor(props.internal.serviceToken);

        ManagedChannel catalogCh = channel(props.peer.catalogGrpcAddr, "catalog");
        ManagedChannel couponCh  = channel(props.peer.couponGrpcAddr, "coupon");
        ManagedChannel walletCh  = channel(props.peer.walletGrpcAddr, "wallet");

        this.catalogStub = CatalogGrpc.newBlockingStub(catalogCh).withInterceptors(tokenInterceptor);
        this.couponStub  = CouponGrpc.newBlockingStub(couponCh).withInterceptors(tokenInterceptor);
        this.walletStub  = WalletGrpc.newBlockingStub(walletCh).withInterceptors(tokenInterceptor);
    }

    private ManagedChannel channel(String addr, String peer) {
        String target = (addr == null || addr.isBlank()) ? "localhost:1" : addr;
        if (addr == null || addr.isBlank()) {
            log.warn("gRPC peer '{}' address is blank — calls will fail until wired", peer);
        }
        // overrideAuthority sets the HTTP/2 :authority to a logical name — the Elastic APM
        // Java agent names the gRPC dependency by the channel authority, so this yields a
        // friendly "grpc-catalog/coupon/wallet" in Dependencies + the service map (not raw IP:port).
        ManagedChannel ch = ManagedChannelBuilder.forTarget(target).usePlaintext()
                .overrideAuthority("grpc-" + peer)
                .build();
        channels.add(ch);
        return ch;
    }

    private ClientInterceptor tokenInterceptor(String token) {
        return new ClientInterceptor() {
            @Override
            public <ReqT, RespT> ClientCall<ReqT, RespT> interceptCall(
                    MethodDescriptor<ReqT, RespT> method, CallOptions callOptions, Channel next) {
                return new ForwardingClientCall.SimpleForwardingClientCall<>(
                        next.newCall(method, callOptions)) {
                    @Override
                    public void start(Listener<RespT> responseListener, Metadata headers) {
                        headers.put(INTERNAL_TOKEN, token == null ? "" : token);
                        super.start(responseListener, headers);
                    }
                };
            }
        };
    }

    public CatalogGrpc.CatalogBlockingStub catalog() { return catalogStub; }
    public CouponGrpc.CouponBlockingStub coupon()    { return couponStub; }
    public WalletGrpc.WalletBlockingStub wallet()    { return walletStub; }

    @PreDestroy
    public void shutdown() {
        for (ManagedChannel ch : channels) {
            try {
                ch.shutdown().awaitTermination(5, TimeUnit.SECONDS);
            } catch (InterruptedException e) {
                Thread.currentThread().interrupt();
                ch.shutdownNow();
            } catch (RuntimeException e) {
                log.warn("error shutting down gRPC channel", e);
            }
        }
    }
}
