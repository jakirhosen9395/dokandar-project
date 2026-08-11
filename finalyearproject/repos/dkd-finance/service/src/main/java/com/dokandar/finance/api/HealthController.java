package com.dokandar.finance.api;

import com.dokandar.finance.config.FinanceProps;
import java.io.FileInputStream;
import java.io.IOException;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.TimeUnit;
import org.apache.kafka.clients.admin.AdminClient;
import org.springframework.http.ResponseEntity;
import org.springframework.jdbc.core.JdbcTemplate;
import org.springframework.kafka.core.KafkaAdmin;
import org.springframework.web.bind.annotation.GetMapping;
import org.springframework.web.bind.annotation.RestController;

/** Fleet health convention: /health /live /ready /version on the main port. */
@RestController
public class HealthController {

    private final JdbcTemplate jdbc;
    private final KafkaAdmin kafkaAdmin;
    private final Map<String, String> buildInfo;
    private volatile AdminClient adminClient;

    public HealthController(JdbcTemplate jdbc, KafkaAdmin kafkaAdmin, FinanceProps props) {
        this.jdbc = jdbc;
        this.kafkaAdmin = kafkaAdmin;
        this.buildInfo = loadBuildInfo(props.buildInfoPath());
    }

    @GetMapping("/health")
    public Map<String, Object> health() {
        return Map.of("status", "ok", "service", "finance-ledger-svc",
            "version", buildInfo.get("version"), "gitSha", buildInfo.get("gitSha"));
    }

    @GetMapping("/live")
    public Map<String, Object> live() {
        return Map.of("status", "ok");
    }

    @GetMapping("/ready")
    public ResponseEntity<Map<String, Object>> ready() {
        boolean db = pingDb();
        boolean kafka = pingKafka();
        Map<String, Object> body = Map.of("status", db && kafka ? "ok" : "degraded",
            "db", db ? "ok" : "down", "kafka", kafka ? "ok" : "down");
        return ResponseEntity.status(db && kafka ? 200 : 503).body(body);
    }

    @GetMapping("/version")
    public Map<String, String> version() {
        return buildInfo;
    }

    private boolean pingDb() {
        try {
            Integer one = jdbc.queryForObject("SELECT 1", Integer.class);
            return one != null && one == 1;
        } catch (RuntimeException e) {
            return false;
        }
    }

    private boolean pingKafka() {
        try {
            if (adminClient == null) {
                synchronized (this) {
                    if (adminClient == null)
                        adminClient = AdminClient.create(kafkaAdmin.getConfigurationProperties());
                }
            }
            return !adminClient.describeCluster().nodes().get(3, TimeUnit.SECONDS).isEmpty();
        } catch (Exception e) {
            return false;
        }
    }

    private static Map<String, String> loadBuildInfo(String path) {
        Properties p = new Properties();
        try (FileInputStream in = new FileInputStream(path)) {
            p.load(in);
        } catch (IOException ignored) {
            // local dev without a build-info file
        }
        return Map.of(
            "service", "finance-ledger-svc",
            "version", p.getProperty("version", "0.0.0-dev"),
            "gitSha", p.getProperty("gitSha", "unknown"),
            "buildTime", p.getProperty("buildTime", "unknown"));
    }
}
