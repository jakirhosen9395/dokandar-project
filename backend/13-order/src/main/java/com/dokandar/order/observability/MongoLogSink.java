package com.dokandar.order.observability;

import com.mongodb.client.MongoClient;
import com.mongodb.client.MongoClients;
import com.mongodb.client.MongoDatabase;
import jakarta.annotation.PreDestroy;
import org.bson.Document;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.stereotype.Component;

import java.time.Instant;

/**
 * Mongo connectivity bean for the {@code /health.mongo_logs} ping. Actual per-log
 * doc shipping is the non-blocking {@link FleetLogAppender} (a logback appender);
 * this bean only proves the cluster is reachable and seeds the collection.
 */
@Component
public class MongoLogSink {

    private static final Logger LOG = LoggerFactory.getLogger(MongoLogSink.class);

    private MongoClient client;
    private MongoDatabase database;

    public MongoLogSink(@Value("${dokandar.mongo.log-uri:}") String uri,
                        @Value("${dokandar.mongo.log-db:mongo_db_dokandar_application_logs}") String db,
                        @Value("${dokandar.service.name:13-order}") String serviceName) {
        if (uri == null || uri.isBlank()) {
            LOG.warn("MONGO_LOG_URI empty — mongo health/seed disabled (stdout JSON still works)");
            return;
        }
        try {
            this.client = MongoClients.create(uri);
            this.database = client.getDatabase(db);
            database.getCollection(serviceName).insertOne(new Document()
                .append("@timestamp", Instant.now().toString())
                .append("message", "13-order service boot")
                .append("service", new Document("name", serviceName)));
            LOG.info("MongoLogSink ready (db={} collection={})", db, serviceName);
        } catch (Exception e) {
            LOG.warn("MongoLogSink init failed: {}", e.getMessage());
        }
    }

    public boolean healthy() {
        if (database == null) return false;
        try { database.runCommand(new Document("ping", 1)); return true; }
        catch (Exception e) { return false; }
    }

    @PreDestroy
    public void close() { if (client != null) client.close(); }
}
