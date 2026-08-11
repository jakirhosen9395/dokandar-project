package com.dokandar.order.api;

import com.dokandar.order.config.CodeVersion;
import com.dokandar.order.config.OrderProperties;
import com.dokandar.order.observability.MongoLogSink;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.swagger.v3.oas.annotations.Hidden;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.tags.Tag;
import org.springframework.data.redis.connection.RedisConnectionFactory;
import org.springframework.http.ResponseEntity;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

import javax.sql.DataSource;
import java.net.InetSocketAddress;
import java.net.Socket;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.util.*;

/**
 * The five operational endpoints, byte-identical across the fleet.
 *
 * <p>{@code /ready} gates PostgreSQL ONLY (spec §8): Temporal, Redis, Kafka, and
 * the gRPC peers are degradable/buffered and must NEVER evict a node still serving
 * order reads/transitions. {@code /health} reports all deps; {@code temporal} and
 * the {@code grpc_*} peer checks are diagnostic and NEVER flip status.
 * {@code /metrics} is served by Actuator→Micrometer (mapped to /metrics);
 * {@code /docs} + {@code /openapi.json} by springdoc.
 */
@RestController
@Tag(name = "ops")
public class OpsController {

    private final DataSource ds;
    private final RedisConnectionFactory redis;
    private final MongoLogSink mongoSink;
    private final OrderProperties props;
    private final ObjectMapper mapper = new ObjectMapper();
    private final long bootMillis = System.currentTimeMillis();

    public OpsController(DataSource ds, RedisConnectionFactory redis, MongoLogSink mongoSink, OrderProperties props) {
        this.ds = ds; this.redis = redis; this.mongoSink = mongoSink; this.props = props;
    }

    private Map<String, Object> identity() {
        Map<String, Object> id = new LinkedHashMap<>();
        id.put("service_name", props.service.name);
        id.put("code_version", CodeVersion.VALUE);
        id.put("env_version", props.service.envVersion);
        id.put("tenant", props.service.tenant);
        id.put("env", props.service.appEnv);
        id.put("uptime_seconds", (System.currentTimeMillis() - bootMillis) / 1000);
        return id;
    }

    @GetMapping("/ready")
    @Operation(operationId = "getReady", summary = "Readiness probe (PostgreSQL only)",
        description = "LB/readiness gate. 200 only when PostgreSQL is reachable; Temporal/Redis/Kafka/gRPC "
                + "peers are degradable and never gate readiness.")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "ready"),
        @ApiResponse(responseCode = "503", description = "not_ready (postgres unreachable)"),
    })
    public ResponseEntity<?> ready() {
        long t = System.nanoTime();
        boolean pg = pgOk();
        double ms = Math.round((System.nanoTime() - t) / 1e5) / 10.0;
        Map<String, Object> dep = new LinkedHashMap<>();
        dep.put("name", "postgres"); dep.put("reachable", pg); dep.put("latency_ms", ms);
        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", pg ? "ready" : "not_ready");
        body.put("identity", identity());
        body.put("dependencies", List.of(dep));
        return ResponseEntity.status(pg ? 200 : 503).body(body);
    }

    @GetMapping("/health")
    @Operation(operationId = "getHealth", summary = "Full health + dependency diagnostics",
        description = "Reports all deps + an observability block. temporal and grpc_* peer checks are "
                + "diagnostic-only and never flip status.")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "healthy"),
        @ApiResponse(responseCode = "503", description = "unhealthy (a core dep is down)"),
    })
    public ResponseEntity<?> health() {
        boolean pg = pgOk();
        boolean rd = redisOk();
        boolean kafka = tcpOk(props.kafka.bootstrap, 9092);
        boolean mongo = mongoSink.healthy();
        String apmServer = props.apm.serverUrl;
        boolean apm = tcpOk(apmServer == null ? null : apmServer.replaceFirst("^https?://", ""), 8200);
        boolean temporal = tcpOk(props.temporal.target, 7233);                 // diagnostic only
        boolean catalog = peerOk(props.peer.catalogGrpcAddr);                  // diagnostic only
        boolean coupon  = peerOk(props.peer.couponGrpcAddr);                   // diagnostic only
        boolean wallet  = peerOk(props.peer.walletGrpcAddr);                   // diagnostic only

        // temporal + grpc peers are NEVER part of `healthy` (spec §8)
        boolean healthy = pg && rd && kafka && mongo && apm;

        Map<String, Object> checks = new LinkedHashMap<>();
        String apmAddr = apmServer == null ? "" : apmServer.replaceFirst("^https?://", "");
        checks.put("postgres",     check(pg, pg ? "ok" : "unreachable"));
        checks.put("redis",        check(rd, rd ? "PONG" : "unreachable"));
        checks.put("kafka",        check(kafka, kafka ? "metadata-ok" : "unreachable"));
        checks.put("mongo_logs",   check(mongo, mongo ? "ping-ok" : "unreachable"));
        checks.put("apm",          check(apm, (apmAddr.isBlank() ? "" : apmAddr + " ") + (apm ? "tcp-ok" : "unreachable")));
        checks.put("temporal",     check(temporal, props.temporal.target + " " + (temporal ? "tcp-ok" : "unreachable")));
        checks.put("grpc_catalog", peerCheck(props.peer.catalogGrpcAddr, catalog));
        checks.put("grpc_coupon",  peerCheck(props.peer.couponGrpcAddr, coupon));
        checks.put("grpc_wallet",  peerCheck(props.peer.walletGrpcAddr, wallet));

        Map<String, Object> obs = new LinkedHashMap<>();
        obs.put("apm_service_name", props.service.name);
        obs.put("apm_server_url", apmServer);
        obs.put("logs_sink_mongo", "mongodb://" + props.mongo.logDb + "/" + props.service.name);
        String esUrl = props.elastic.url;
        obs.put("logs_sink_es", esUrl == null || esUrl.isBlank() ? "disabled" : esUrl + "/logs-app-" + props.service.name + "-*");

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", healthy ? "healthy" : "unhealthy");
        body.put("identity", identity());
        body.put("checks", checks);
        body.put("observability", obs);
        return ResponseEntity.status(healthy ? 200 : 503).body(body);
    }

    @GetMapping("/data")
    @Operation(operationId = "getData", summary = "Identity block + read-only host snapshot",
        description = "Returns the identity block prepended to the read-only data/<tenant>/result.json "
                + "snapshot (not live DB introspection).")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "identity + snapshot"),
        @ApiResponse(responseCode = "404", description = "no_snapshot",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
        @ApiResponse(responseCode = "500", description = "snapshot_parse_failed",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = "#/components/schemas/ErrorEnvelope"))),
    })
    public ResponseEntity<?> data() {
        String tenant = props.service.tenant;
        for (Path f : new Path[]{ Path.of("data", tenant, "result.json"), Path.of("/app/data", tenant, "result.json") }) {
            if (Files.exists(f)) {
                LinkedHashMap<String, Object> snap;
                try {
                    snap = mapper.readValue(Files.readString(f), new TypeReference<LinkedHashMap<String, Object>>() {});
                } catch (Exception e) {
                    throw new ApiException(500, "snapshot_parse_failed", "data/" + tenant + "/result.json is present but not valid JSON");
                }
                LinkedHashMap<String, Object> out = new LinkedHashMap<>();
                out.put("identity", identity());
                out.putAll(snap);
                return ResponseEntity.ok(out);
            }
        }
        throw new ApiException(404, "no_snapshot", "data/" + tenant + "/result.json not present (run data/" + tenant + "/collect.sh)");
    }

    @GetMapping("/favicon.ico")
    @Hidden
    public ResponseEntity<Void> favicon() { return ResponseEntity.noContent().build(); }

    // ---- helpers -----------------------------------------------------------

    private static Map<String, Object> check(boolean ok, String detail) {
        Map<String, Object> m = new LinkedHashMap<>();
        m.put("ok", ok); m.put("detail", detail);
        return m;
    }
    /** A gRPC peer check that is "not_configured" (not a failure) when the addr is unset. */
    private static Map<String, Object> peerCheck(String addr, boolean ok) {
        boolean set = addr != null && !addr.isBlank();
        return check(ok, set ? addr + " " + (ok ? "tcp-ok" : "unreachable") : "not_configured");
    }
    private static boolean peerOk(String addr) { return addr != null && !addr.isBlank() && tcpOk(addr, 9090); }

    private boolean pgOk() { try (Connection c = ds.getConnection()) { return c.isValid(2); } catch (Exception e) { return false; } }
    private boolean redisOk() { try (var c = redis.getConnection()) { return "PONG".equalsIgnoreCase(new String(c.ping())); } catch (Exception e) { return false; } }

    private static boolean tcpOk(String hostport, int defaultPort) {
        if (hostport == null || hostport.isBlank()) return false;
        try {
            String first = hostport.split(",")[0];
            // strip a scheme + path if present (e.g. http://host:port, dns:///host:port)
            first = first.replaceFirst("^[a-zA-Z]+://", "");
            first = first.replaceFirst("/.*$", "");
            String[] parts = first.split(":");
            String host = parts[0];
            int port = parts.length > 1 ? Integer.parseInt(parts[parts.length - 1].replaceAll("[^0-9]", "")) : defaultPort;
            try (Socket s = new Socket()) { s.connect(new InetSocketAddress(host, port), 2000); return true; }
        } catch (Exception e) { return false; }
    }
}
