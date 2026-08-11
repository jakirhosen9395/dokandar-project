package com.dokandar.order.config;

import jakarta.annotation.PostConstruct;
import org.flywaydb.core.Flyway;
import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.beans.factory.annotation.Value;
import org.springframework.boot.jpa.autoconfigure.EntityManagerFactoryDependsOnPostProcessor;
import org.springframework.context.annotation.Bean;
import org.springframework.context.annotation.Configuration;
import org.springframework.stereotype.Component;

import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.Statement;
import java.util.regex.Pattern;

/**
 * Boot-time database bootstrap: create the order database if missing (Postgres
 * can't CREATE DATABASE from JPA), then run Flyway migrations programmatically.
 *
 * <p>Flyway OWNS the schema (architecture.md §14 / V1__init.sql). Spring Boot's
 * Flyway auto-config is disabled ({@code spring.flyway.enabled=false}) because it
 * would connect to the app DB at an arbitrary point in startup — possibly BEFORE
 * the DB exists. Running migrate() here, right after ensureDatabase(), guarantees
 * the order: create-db -> migrate -> (then) the EntityManagerFactory.
 *
 * <p>Hibernate opens a connection while building the EMF, so this bean MUST run
 * first — {@link JpaDependsOnDbBootstrap} declares the EMF to depend on it
 * (the same mechanism Spring Boot uses to order Flyway before Hibernate).
 */
@Component
public class DbBootstrap {

    private static final Logger LOG = LoggerFactory.getLogger(DbBootstrap.class);
    private static final Pattern SAFE = Pattern.compile("^[A-Za-z_][A-Za-z0-9_]*$");

    @Value("${POSTGRES_HOST:localhost}")          private String host;
    @Value("${POSTGRES_PORT:5432}")               private String port;
    @Value("${POSTGRES_USER:postgres}")           private String user;
    @Value("${POSTGRES_PASSWORD:}")               private String pass;
    @Value("${POSTGRES_DB:dokandar_order_dev}")   private String dbName;

    @PostConstruct
    public void ensure() {
        if (!SAFE.matcher(dbName).matches())
            throw new IllegalStateException("unsafe POSTGRES_DB: " + dbName);
        ensureDatabase();
        migrate();
    }

    @Configuration(proxyBeanMethods = false)
    static class JpaDependsOnDbBootstrap {
        @Bean
        static EntityManagerFactoryDependsOnPostProcessor dbBootstrapJpaDependency() {
            return new EntityManagerFactoryDependsOnPostProcessor("dbBootstrap");
        }
    }

    private void ensureDatabase() {
        String adminUrl = "jdbc:postgresql://" + host + ":" + port + "/postgres";
        try (Connection c = DriverManager.getConnection(adminUrl, user, pass);
             Statement st = c.createStatement()) {
            try (ResultSet rs = st.executeQuery("SELECT 1 FROM pg_database WHERE datname = '" + dbName + "'")) {
                if (rs.next()) { LOG.info("[ensure-db] database {} already exists", dbName); return; }
            }
            LOG.info("[ensure-db] creating database {}", dbName);
            st.executeUpdate("CREATE DATABASE \"" + dbName + "\"");
        } catch (Exception e) {
            throw new IllegalStateException("[ensure-db] failed for " + dbName, e);
        }
    }

    private void migrate() {
        String url = "jdbc:postgresql://" + host + ":" + port + "/" + dbName;
        Flyway flyway = Flyway.configure()
                .dataSource(url, user, pass)
                .locations("classpath:db/migration")
                .baselineOnMigrate(true)
                .load();
        flyway.migrate();
        LOG.info("[ensure-db] Flyway migrations applied");
    }
}
