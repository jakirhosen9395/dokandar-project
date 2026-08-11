package com.dokandar.catalog.api;

import com.dokandar.catalog.observability.MongoLogSink;
import com.fasterxml.jackson.core.type.TypeReference;
import com.fasterxml.jackson.databind.ObjectMapper;
import io.swagger.v3.oas.annotations.Hidden;
import io.swagger.v3.oas.annotations.Operation;
import io.swagger.v3.oas.annotations.media.Content;
import io.swagger.v3.oas.annotations.media.Schema;
import io.swagger.v3.oas.annotations.responses.ApiResponse;
import io.swagger.v3.oas.annotations.responses.ApiResponses;
import io.swagger.v3.oas.annotations.tags.Tag;
import org.springframework.beans.factory.annotation.Value;
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
 * {@code /ready} gates PostgreSQL ONLY (Redis DB 3 is a degradable cache —
 * §16-a). {@code /health} reports all deps; {@code grpc_media} is diagnostic and
 * never flips the status. {@code /metrics} is served by Actuator→Micrometer
 * (mapped to /metrics); {@code /docs} + {@code /openapi.json} by springdoc.
 */
@RestController
@Tag(name = "ops", description = "Operational / contract surface (/ready /health /data /metrics)")
public class OpsController {

    private static final String ERR = "#/components/schemas/ErrorEnvelope";

    private final DataSource ds;
    private final RedisConnectionFactory redis;
    private final MongoLogSink mongoSink;
    private final ObjectMapper mapper = new ObjectMapper();

    private final String serviceName, envVersion, tenant, env, kafkaBootstrap, apmServer, mediaGrpc, mongoDb, esUrl;
    private final long bootMillis = System.currentTimeMillis();

    public OpsController(DataSource ds, RedisConnectionFactory redis, MongoLogSink mongoSink,
                         @Value("${dokandar.service.name}") String serviceName,
                         @Value("${dokandar.service.env-version}") String envVersion,
                         @Value("${dokandar.service.tenant}") String tenant,
                         @Value("${dokandar.service.app-env}") String env,
                         @Value("${dokandar.kafka.bootstrap:}") String kafkaBootstrap,
                         @Value("${dokandar.apm.server-url:}") String apmServer,
                         @Value("${dokandar.media.grpc-addr:}") String mediaGrpc,
                         @Value("${dokandar.mongo.log-db:mongo_db_dokandar_application_logs}") String mongoDb,
                         @Value("${dokandar.elastic.url:}") String esUrl) {
        this.ds = ds; this.redis = redis; this.mongoSink = mongoSink;
        this.serviceName = serviceName; this.envVersion = envVersion; this.tenant = tenant; this.env = env;
        this.kafkaBootstrap = kafkaBootstrap; this.apmServer = apmServer; this.mediaGrpc = mediaGrpc;
        this.mongoDb = mongoDb; this.esUrl = esUrl;
    }

    private Map<String, Object> identity() {
        Map<String, Object> id = new LinkedHashMap<>();
        id.put("service_name", serviceName);
        id.put("code_version", codeVersion());
        id.put("env_version", envVersion);
        id.put("tenant", tenant);
        id.put("env", env);
        id.put("uptime_seconds", (System.currentTimeMillis() - bootMillis) / 1000);
        return id;
    }

    static String codeVersion() {
        for (String p : new String[]{"CODE_VERSION", "/app/CODE_VERSION"}) {
            try { return Files.readString(Path.of(p)).trim(); } catch (Exception ignored) {}
        }
        return "04-catalog";
    }

    @GetMapping("/ready")
    @Operation(operationId = "getReady", summary = "Readiness probe (postgres only)",
        description = "LB readiness gate. 200 when PostgreSQL is reachable; Redis is a degradable cache and is NOT gated here.",
        tags = "ops")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "ready"),
        @ApiResponse(responseCode = "503", description = "not_ready")
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
    @Operation(operationId = "getHealth", summary = "Full health + dependency checks",
        description = "Full diagnostics over all deps plus an observability block. `grpc_media` is diagnostic-only and never flips status.",
        tags = "ops")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "healthy"),
        @ApiResponse(responseCode = "503", description = "unhealthy")
    })
    public ResponseEntity<?> health() {
        boolean pg = pgOk();
        boolean rd = redisOk();
        boolean kafka = tcpOk(kafkaBootstrap, 9092);
        boolean mongo = mongoSink.healthy();
        boolean apm = tcpOk(apmServer.replaceFirst("^https?://", ""), 8200);
        boolean mediaSet = mediaGrpc != null && !mediaGrpc.isBlank();
        boolean media = mediaSet && tcpOk(mediaGrpc, 50051);

        boolean healthy = pg && rd && kafka && mongo && apm;   // grpc_media is diagnostic only

        Map<String, Object> checks = new LinkedHashMap<>();
        String apmAddr = apmServer == null ? "" : apmServer.replaceFirst("^https?://", "");
        checks.put("postgres",   check(pg, pg ? "ok" : "unreachable"));
        checks.put("redis",      check(rd, rd ? "PONG" : "unreachable"));
        checks.put("kafka",      check(kafka, kafka ? "metadata-ok" : "unreachable"));
        checks.put("mongo_logs", check(mongo, mongo ? "ping-ok" : "unreachable"));
        checks.put("apm",        check(apm, (apmAddr.isBlank() ? "" : apmAddr + " ") + (apm ? "tcp-ok" : "unreachable")));
        checks.put("grpc_media", check(media, mediaSet ? (mediaGrpc + " " + (media ? "tcp-ok" : "unreachable")) : "not_configured"));

        Map<String, Object> obs = new LinkedHashMap<>();
        obs.put("apm_service_name", serviceName);
        obs.put("apm_server_url", apmServer);
        obs.put("logs_sink_mongo", "mongodb://" + mongoDb + "/" + serviceName);
        obs.put("logs_sink_es", esUrl == null || esUrl.isBlank() ? "disabled" : esUrl + "/logs-app-" + serviceName + "-*");

        Map<String, Object> body = new LinkedHashMap<>();
        body.put("status", healthy ? "healthy" : "unhealthy");
        body.put("identity", identity());
        body.put("checks", checks);
        body.put("observability", obs);
        return ResponseEntity.status(healthy ? 200 : 503).body(body);
    }

    @GetMapping("/data")
    @Operation(operationId = "getData", summary = "Identity + /data snapshot",
        description = "Identity block prepended to the read-only data/<tenant>/result.json snapshot.",
        tags = "ops")
    @ApiResponses({
        @ApiResponse(responseCode = "200", description = "snapshot"),
        @ApiResponse(responseCode = "404", description = "no_snapshot",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR))),
        @ApiResponse(responseCode = "500", description = "snapshot_parse_failed",
            content = @Content(mediaType = "application/json", schema = @Schema(ref = ERR)))
    })
    public ResponseEntity<?> data() {
        for (Path f : new Path[]{ Path.of("data", tenant, "result.json"), Path.of("/app/data", tenant, "result.json") }) {
            if (Files.exists(f)) {
                LinkedHashMap<String, Object> snap;
                try {
                    snap = mapper.readValue(Files.readString(f), new TypeReference<LinkedHashMap<String, Object>>() {});
                } catch (Exception e) {
                    // canonical envelope (request_id-correlated) via the advice; generic message, no leak
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
    private boolean pgOk() { try (Connection c = ds.getConnection()) { return c.isValid(2); } catch (Exception e) { return false; } }
    private boolean redisOk() { try (var c = redis.getConnection()) { return "PONG".equalsIgnoreCase(new String(c.ping())); } catch (Exception e) { return false; } }

    private static boolean tcpOk(String hostport, int defaultPort) {
        if (hostport == null || hostport.isBlank()) return false;
        try {
            String first = hostport.split(",")[0];
            String[] parts = first.split(":");
            String host = parts[0];
            int port = parts.length > 1 ? Integer.parseInt(parts[1].replaceAll("[^0-9]", "")) : defaultPort;
            try (Socket s = new Socket()) { s.connect(new InetSocketAddress(host, port), 2000); return true; }
        } catch (Exception e) { return false; }
    }
}
