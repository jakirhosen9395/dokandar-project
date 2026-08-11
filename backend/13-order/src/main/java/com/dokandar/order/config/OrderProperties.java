package com.dokandar.order.config;

import org.springframework.boot.context.properties.ConfigurationProperties;
import org.springframework.boot.context.properties.NestedConfigurationProperty;

/**
 * Typed binding of every {@code dokandar.*} config key (env vars rendered by
 * env/init-env.sh). Injected wherever the saga / clients / ops need them; the
 * raw POSTGRES_* are still read discretely by {@link DbBootstrap} (it runs before
 * the Spring DataSource exists).
 *
 * <p>NOTE: Spring Boot's JavaBean binder populates nested holders via their
 * getters and binds each scalar via a setter — public fields alone are NOT bound.
 * Each nested class therefore exposes get/set for every scalar; the call sites
 * still read {@code props.service.name} etc. directly off the (public) field, which
 * the binder has populated through the setter.
 */
@ConfigurationProperties(prefix = "dokandar")
public class OrderProperties {

    @NestedConfigurationProperty public final Service  service  = new Service();
    @NestedConfigurationProperty public final Grpc     grpc     = new Grpc();
    @NestedConfigurationProperty public final Internal internal = new Internal();
    @NestedConfigurationProperty public final Jwt      jwt      = new Jwt();
    @NestedConfigurationProperty public final Kafka    kafka    = new Kafka();
    @NestedConfigurationProperty public final Mongo    mongo    = new Mongo();
    @NestedConfigurationProperty public final Elastic  elastic  = new Elastic();
    @NestedConfigurationProperty public final Apm      apm      = new Apm();
    @NestedConfigurationProperty public final Temporal temporal = new Temporal();
    @NestedConfigurationProperty public final Peer     peer     = new Peer();
    @NestedConfigurationProperty public final Topic    topic    = new Topic();

    // nested getters so the binder recurses into the pre-instantiated instances
    public Service getService()   { return service; }
    public Grpc getGrpc()         { return grpc; }
    public Internal getInternal() { return internal; }
    public Jwt getJwt()           { return jwt; }
    public Kafka getKafka()       { return kafka; }
    public Mongo getMongo()       { return mongo; }
    public Elastic getElastic()   { return elastic; }
    public Apm getApm()           { return apm; }
    public Temporal getTemporal() { return temporal; }
    public Peer getPeer()         { return peer; }
    public Topic getTopic()       { return topic; }

    public static class Service {
        public String name;                 // required (no default) — fail-fast if blank
        public String envVersion = "v1.0.0";
        public String tenant = "cloud";
        public String appEnv = "dev";
        public String getName() { return name; } public void setName(String v) { name = v; }
        public String getEnvVersion() { return envVersion; } public void setEnvVersion(String v) { envVersion = v; }
        public String getTenant() { return tenant; } public void setTenant(String v) { tenant = v; }
        public String getAppEnv() { return appEnv; } public void setAppEnv(String v) { appEnv = v; }
    }
    public static class Grpc {
        public int port = 9090;
        public boolean enabled = true;
        public int getPort() { return port; } public void setPort(int v) { port = v; }
        public boolean isEnabled() { return enabled; } public void setEnabled(boolean v) { enabled = v; }
    }
    public static class Internal {
        public String serviceToken = "";    // INTERNAL_SERVICE_TOKEN — const-time compared
        public String getServiceToken() { return serviceToken; } public void setServiceToken(String v) { serviceToken = v; }
    }
    public static class Jwt {
        public String publicKeyB64 = "";
        public String issuer = "dokandar-auth";
        public String getPublicKeyB64() { return publicKeyB64; } public void setPublicKeyB64(String v) { publicKeyB64 = v; }
        public String getIssuer() { return issuer; } public void setIssuer(String v) { issuer = v; }
    }
    public static class Kafka {
        public String bootstrap = "";
        public String getBootstrap() { return bootstrap; } public void setBootstrap(String v) { bootstrap = v; }
    }
    public static class Mongo {
        public String logUri = "";
        public String logDb = "mongo_db_dokandar_application_logs";
        public String getLogUri() { return logUri; } public void setLogUri(String v) { logUri = v; }
        public String getLogDb() { return logDb; } public void setLogDb(String v) { logDb = v; }
    }
    public static class Elastic {
        public String url = "";
        public String username = "elastic";
        public String password = "";
        public String getUrl() { return url; } public void setUrl(String v) { url = v; }
        public String getUsername() { return username; } public void setUsername(String v) { username = v; }
        public String getPassword() { return password; } public void setPassword(String v) { password = v; }
    }
    public static class Apm {
        public String serverUrl = "";
        public String getServerUrl() { return serverUrl; } public void setServerUrl(String v) { serverUrl = v; }
    }
    /** Saga state. Reported on /health, NEVER a /ready gate (spec §8). */
    public static class Temporal {
        public String target = "localhost:7233";       // overridden by TEMPORAL_TARGET / TEMPORAL_HOST (safe default — never the real infra IP)
        public String namespace = "default";          // custom ns must be pre-registered on the server
        public String taskQueue = "checkout-saga";     // ONE value used by both worker + WorkflowStub
        public String getTarget() { return target; } public void setTarget(String v) { target = v; }
        public String getNamespace() { return namespace; } public void setNamespace(String v) { namespace = v; }
        public String getTaskQueue() { return taskQueue; } public void setTaskQueue(String v) { taskQueue = v; }
    }
    /** East-west peers. Empty = feature disabled until wired at deploy; diagnostic on /health. */
    public static class Peer {
        public String catalogGrpcAddr = "";
        public String couponGrpcAddr = "";
        public String walletGrpcAddr = "";
        public String paymentRestUrl = "";
        public String getCatalogGrpcAddr() { return catalogGrpcAddr; } public void setCatalogGrpcAddr(String v) { catalogGrpcAddr = v; }
        public String getCouponGrpcAddr() { return couponGrpcAddr; } public void setCouponGrpcAddr(String v) { couponGrpcAddr = v; }
        public String getWalletGrpcAddr() { return walletGrpcAddr; } public void setWalletGrpcAddr(String v) { walletGrpcAddr = v; }
        public String getPaymentRestUrl() { return paymentRestUrl; } public void setPaymentRestUrl(String v) { paymentRestUrl = v; }
    }
    /** Kafka topics (literal per service; TENANT must NOT change them). */
    public static class Topic {
        public String orderPlaced = "dokandar.order.placed";
        public String orderConfirmed = "dokandar.order.confirmed";
        public String orderStatusChanged = "dokandar.order.status_changed";
        public String orderDelivered = "dokandar.order.delivered";
        public String orderRefunded = "dokandar.order.refunded";
        public String orderCancelled = "dokandar.order.cancelled";
        public String paymentSettled = "dokandar.payment.settled";
        public String getOrderPlaced() { return orderPlaced; } public void setOrderPlaced(String v) { orderPlaced = v; }
        public String getOrderConfirmed() { return orderConfirmed; } public void setOrderConfirmed(String v) { orderConfirmed = v; }
        public String getOrderStatusChanged() { return orderStatusChanged; } public void setOrderStatusChanged(String v) { orderStatusChanged = v; }
        public String getOrderDelivered() { return orderDelivered; } public void setOrderDelivered(String v) { orderDelivered = v; }
        public String getOrderRefunded() { return orderRefunded; } public void setOrderRefunded(String v) { orderRefunded = v; }
        public String getOrderCancelled() { return orderCancelled; } public void setOrderCancelled(String v) { orderCancelled = v; }
        public String getPaymentSettled() { return paymentSettled; } public void setPaymentSettled(String v) { paymentSettled = v; }
    }
}
