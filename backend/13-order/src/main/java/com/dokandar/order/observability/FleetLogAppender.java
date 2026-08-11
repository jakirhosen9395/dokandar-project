package com.dokandar.order.observability;

import ch.qos.logback.classic.spi.ILoggingEvent;
import ch.qos.logback.core.AppenderBase;
import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoCollection;
import org.bson.Document;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Base64;
import java.util.List;
import java.util.concurrent.ArrayBlockingQueue;
import java.util.concurrent.BlockingQueue;
import java.util.concurrent.TimeUnit;

/**
 * The 3rd + 4th log sinks (Mongo + Elasticsearch). A logback appender — instantiated
 * by logback (NOT Spring), so it reads config from the environment directly. Each
 * event is offered to a bounded queue and a single daemon thread drains it to
 * Mongo {@code <db>.<service>} (insertMany) and ES {@code logs-app-<service>-*}
 * (_bulk). Fire-and-forget: a slow/failed sink DROPS lines, never back-pressures
 * the request path, and never breaks logback init (everything is try/catch).
 * ES bulk doc carries NO {@code _id} (§16-f) — fresh doc per sink.
 */
public class FleetLogAppender extends AppenderBase<ILoggingEvent> {

    private static final int QUEUE_CAP = 10_000;
    private static final int BATCH = 200;

    private final BlockingQueue<ILoggingEvent> queue = new ArrayBlockingQueue<>(QUEUE_CAP);
    private volatile boolean running = false;
    private Thread drainer;

    private String service = envOr("SERVICE_NAME", "13-order");
    private MongoClient mongoClient;
    private MongoCollection<Document> mongoCol;
    private HttpClient http;
    private String esBulkUrl;
    private String esAuthHeader;

    @Override
    public void start() {
        try {
            String mongoUri = System.getenv("MONGO_LOG_URI");
            String mongoDb = envOr("MONGO_LOG_DB", "mongo_db_dokandar_application_logs");
            if (mongoUri != null && !mongoUri.isBlank()) {
                mongoClient = MongoClients.create(mongoUri);
                mongoCol = mongoClient.getDatabase(mongoDb).getCollection(service);
            }
            String esUrl = System.getenv("ELASTIC_SEARCH_URL");
            if (esUrl != null && !esUrl.isBlank()) {
                http = HttpClient.newBuilder().connectTimeout(java.time.Duration.ofSeconds(3)).build();
                esBulkUrl = esUrl.replaceAll("/+$", "") + "/logs-app-" + service + "-default/_bulk";
                String u = envOr("ELASTIC_SEARCH_USERNAME", ""), p = envOr("ELASTIC_SEARCH_PASSWORD", "");
                if (!u.isBlank())
                    esAuthHeader = "Basic " + Base64.getEncoder().encodeToString((u + ":" + p).getBytes(StandardCharsets.UTF_8));
            }
            if (mongoCol != null || esBulkUrl != null) {
                running = true;
                drainer = new Thread(this::drainLoop, "fleet-log-drainer");
                drainer.setDaemon(true);
                drainer.start();
            }
        } catch (Exception e) {
            addError("FleetLogAppender start failed (logging continues on stdout): " + e.getMessage());
        }
        super.start();
    }

    @Override
    protected void append(ILoggingEvent e) {
        if (!running) return;
        String logger = e.getLoggerName();
        if (logger != null && (logger.startsWith("org.mongodb") || logger.startsWith("io.netty"))) return; // avoid sink feedback loops
        queue.offer(e); // bounded, non-blocking — drop on overflow
    }

    private void drainLoop() {
        List<ILoggingEvent> batch = new ArrayList<>(BATCH);
        while (running || !queue.isEmpty()) {
            try {
                ILoggingEvent first = queue.poll(1, TimeUnit.SECONDS);
                if (first == null) continue;
                batch.clear();
                batch.add(first);
                queue.drainTo(batch, BATCH - 1);
                shipMongo(batch);
                shipEs(batch);
            } catch (InterruptedException ie) {
                Thread.currentThread().interrupt();
                return;
            } catch (Exception ex) {
                // swallow — never let the drainer die or back-pressure
            }
        }
    }

    private void shipMongo(List<ILoggingEvent> batch) {
        if (mongoCol == null) return;
        try {
            List<Document> docs = new ArrayList<>(batch.size());
            for (ILoggingEvent e : batch) {
                Document d = new Document()
                    .append("asctime", Instant.ofEpochMilli(e.getTimeStamp()).toString())
                    .append("name", shortLogger(e.getLoggerName()))
                    .append("levelname", e.getLevel().toString())
                    .append("message", e.getFormattedMessage());
                String tid = mdc(e, "trace.id"), txn = mdc(e, "transaction.id");
                if (tid != null) d.append("trace.id", tid);
                if (txn != null) d.append("transaction.id", txn);
                docs.add(d); // fresh doc — Mongo injects _id here only, never reused for ES
            }
            mongoCol.insertMany(docs);
        } catch (Exception ex) { /* drop */ }
    }

    private void shipEs(List<ILoggingEvent> batch) {
        if (esBulkUrl == null || http == null) return;
        try {
            StringBuilder ndjson = new StringBuilder();
            for (ILoggingEvent e : batch) {
                ndjson.append("{\"create\":{}}\n");          // empty action — NO _id (§16-f)
                ndjson.append("{\"@timestamp\":\"").append(Instant.ofEpochMilli(e.getTimeStamp())).append('"')
                      .append(",\"message\":").append(jsonStr(e.getFormattedMessage()))
                      .append(",\"log\":{\"level\":\"").append(e.getLevel()).append("\"}")
                      .append(",\"service\":{\"name\":\"").append(service).append("\"}");
                String tid = mdc(e, "trace.id"), txn = mdc(e, "transaction.id");
                if (tid != null) ndjson.append(",\"trace\":{\"id\":\"").append(tid).append("\"}");
                if (txn != null) ndjson.append(",\"transaction\":{\"id\":\"").append(txn).append("\"}");
                ndjson.append("}\n");
            }
            HttpRequest.Builder rb = HttpRequest.newBuilder(URI.create(esBulkUrl))
                .timeout(java.time.Duration.ofSeconds(5))
                .header("Content-Type", "application/x-ndjson")
                .POST(HttpRequest.BodyPublishers.ofString(ndjson.toString(), StandardCharsets.UTF_8));
            if (esAuthHeader != null) rb.header("Authorization", esAuthHeader);
            http.send(rb.build(), HttpResponse.BodyHandlers.discarding());
        } catch (Exception ex) { /* drop */ }
    }

    @Override
    public void stop() {
        running = false;
        try { if (drainer != null) drainer.join(2000); } catch (InterruptedException ignored) { Thread.currentThread().interrupt(); }
        try { if (mongoClient != null) mongoClient.close(); } catch (Exception ignored) {}
        super.stop();
    }

    private static String mdc(ILoggingEvent e, String key) {
        var m = e.getMDCPropertyMap();
        if (m == null) return null;
        String v = m.get(key);
        return (v == null || v.isBlank()) ? null : v;
    }
    private static String shortLogger(String l) {
        if (l == null) return "order";
        int i = l.lastIndexOf('.');
        return i >= 0 ? l.substring(i + 1) : l;
    }
    private static String jsonStr(String s) {
        if (s == null) return "\"\"";
        StringBuilder b = new StringBuilder("\"");
        for (int i = 0; i < s.length(); i++) {
            char c = s.charAt(i);
            switch (c) {
                case '"' -> b.append("\\\"");
                case '\\' -> b.append("\\\\");
                case '\n' -> b.append("\\n");
                case '\r' -> b.append("\\r");
                case '\t' -> b.append("\\t");
                default -> { if (c < 0x20) b.append(String.format("\\u%04x", (int) c)); else b.append(c); }
            }
        }
        return b.append('"').toString();
    }
    private static String envOr(String k, String d) { String v = System.getenv(k); return (v == null || v.isBlank()) ? d : v; }
}
