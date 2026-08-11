package com.dokandar.catalog;

import jakarta.annotation.PostConstruct;
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
 * Creates the catalog database (Postgres can't create from JPA) and applies the
 * schema idempotently via raw {@link DriverManager} connections, so it runs with
 * no database present.
 *
 * <p>Deliberate deviation from architecture.md §14 (which names Flyway): the
 * proven Java reference (13-order) uses raw idempotent DDL in a DbBootstrap, so
 * this matches the fleet's real Java pattern and keeps the deploy story short
 * (no Flyway tooling at runtime). The schema follows architecture.md §3 exactly.
 *
 * <p>Hibernate opens a connection while building the EntityManagerFactory (to
 * read JDBC metadata), so this bean MUST run first — {@link JpaDependsOnDbBootstrap}
 * declares the EMF to depend on it (§16-i, the same mechanism Spring Boot uses to
 * order Flyway before Hibernate).
 */
@Component
public class DbBootstrap {

    private static final Logger LOG = LoggerFactory.getLogger(DbBootstrap.class);
    private static final Pattern SAFE = Pattern.compile("^[A-Za-z_][A-Za-z0-9_]*$");

    @Value("${POSTGRES_HOST:localhost}")   private String host;
    @Value("${POSTGRES_PORT:5432}")        private String port;
    @Value("${POSTGRES_USER:postgres}")    private String user;
    @Value("${POSTGRES_PASSWORD:}")        private String pass;
    @Value("${POSTGRES_DB:dokandar_catalog_dev}") private String dbName;

    @PostConstruct
    public void ensure() {
        if (!SAFE.matcher(dbName).matches())
            throw new IllegalStateException("unsafe POSTGRES_DB: " + dbName);
        ensureDatabase();
        applySchema();
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

    private void applySchema() {
        String url = "jdbc:postgresql://" + host + ":" + port + "/" + dbName;
        try (Connection c = DriverManager.getConnection(url, user, pass);
             Statement st = c.createStatement()) {
            st.execute(DDL);
            LOG.info("[ensure-db] schema applied");
        } catch (Exception e) {
            throw new IllegalStateException("[ensure-db] schema apply failed", e);
        }
    }

    // architecture.md §3 — idempotent (CREATE … IF NOT EXISTS). No cross-service FK.
    private static final String DDL = """
        CREATE EXTENSION IF NOT EXISTS pgcrypto;
        CREATE EXTENSION IF NOT EXISTS pg_trgm;

        CREATE TABLE IF NOT EXISTS product_categories (
            id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            name_bn     VARCHAR(80) NOT NULL,
            name_en     VARCHAR(80) NOT NULL,
            parent_id   UUID REFERENCES product_categories(id),
            defined_by  VARCHAR(20) NOT NULL,
            owner_id    UUID,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        );
        CREATE INDEX IF NOT EXISTS idx_product_cat_parent ON product_categories(parent_id);

        CREATE TABLE IF NOT EXISTS products (
            id             UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            owner_id       UUID NOT NULL,
            name_bn        VARCHAR(255),
            name_en        VARCHAR(255),
            description_bn TEXT,
            description_en TEXT,
            brand          VARCHAR(80),
            sku            VARCHAR(120),
            category_id    UUID REFERENCES product_categories(id),
            sharing_model  VARCHAR(20) NOT NULL DEFAULT 'shared',
            list_price_minor INT NOT NULL,
            sale_price_minor INT,
            backorderable  BOOLEAN NOT NULL DEFAULT true,
            status         VARCHAR(20) NOT NULL DEFAULT 'draft',
            created_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at     TIMESTAMPTZ NOT NULL DEFAULT now(),
            CHECK (name_bn IS NOT NULL OR name_en IS NOT NULL)
        );
        CREATE INDEX IF NOT EXISTS idx_products_owner   ON products(owner_id);
        CREATE INDEX IF NOT EXISTS idx_products_status  ON products(status) WHERE status='active';
        CREATE INDEX IF NOT EXISTS idx_products_name_bn ON products USING gin (name_bn gin_trgm_ops);
        CREATE INDEX IF NOT EXISTS idx_products_name_en ON products USING gin (name_en gin_trgm_ops);

        CREATE TABLE IF NOT EXISTS product_variants (
            id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            product_id       UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            name_bn          VARCHAR(120),
            name_en          VARCHAR(120),
            attributes       JSONB,
            list_price_minor INT NOT NULL,
            sale_price_minor INT,
            sku              VARCHAR(120),
            created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
            updated_at       TIMESTAMPTZ NOT NULL DEFAULT now()
        );
        CREATE INDEX IF NOT EXISTS idx_variants_product ON product_variants(product_id);

        CREATE TABLE IF NOT EXISTS product_listings (
            id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            product_id  UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            shop_id     UUID NOT NULL,
            visible     BOOLEAN NOT NULL DEFAULT true,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            UNIQUE (product_id, shop_id)
        );
        CREATE INDEX IF NOT EXISTS idx_listings_shop ON product_listings(shop_id) WHERE visible=true;

        CREATE TABLE IF NOT EXISTS product_images (
            id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            product_id  UUID NOT NULL REFERENCES products(id) ON DELETE CASCADE,
            variant_id  UUID REFERENCES product_variants(id) ON DELETE CASCADE,
            s3_key      VARCHAR(255) NOT NULL,
            position    INT NOT NULL DEFAULT 0,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now()
        );

        CREATE TABLE IF NOT EXISTS stock (
            id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            variant_id    UUID NOT NULL REFERENCES product_variants(id) ON DELETE CASCADE,
            shop_id       UUID,
            on_hand       INT NOT NULL DEFAULT 0,
            reserved      INT NOT NULL DEFAULT 0,
            low_threshold INT NOT NULL DEFAULT 5,
            updated_at    TIMESTAMPTZ NOT NULL DEFAULT now()
        );
        CREATE UNIQUE INDEX IF NOT EXISTS uniq_stock_variant_shop
            ON stock (variant_id, COALESCE(shop_id, '00000000-0000-0000-0000-000000000000'::uuid));
        CREATE INDEX IF NOT EXISTS idx_stock_variant ON stock(variant_id);

        CREATE TABLE IF NOT EXISTS stock_reservations (
            id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
            idempotency_key VARCHAR(120) NOT NULL UNIQUE,
            order_id        UUID NOT NULL,
            variant_id      UUID NOT NULL,
            shop_id         UUID,
            quantity        INT NOT NULL,
            backordered     BOOLEAN NOT NULL DEFAULT false,
            state           VARCHAR(20) NOT NULL DEFAULT 'reserved',
            created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
            expires_at      TIMESTAMPTZ NOT NULL DEFAULT now() + INTERVAL '15 minutes'
        );
        CREATE INDEX IF NOT EXISTS idx_reservations_order  ON stock_reservations(order_id);
        CREATE INDEX IF NOT EXISTS idx_reservations_expiry ON stock_reservations(expires_at) WHERE state='reserved';

        CREATE TABLE IF NOT EXISTS outbox (
            id          BIGSERIAL PRIMARY KEY,
            topic       VARCHAR(120) NOT NULL,
            key         VARCHAR(120),
            payload     JSONB NOT NULL,
            created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
            sent_at     TIMESTAMPTZ
        );
        CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;

        -- updated_at must advance on every UPDATE (the entity delegates timestamps to the DB).
        CREATE OR REPLACE FUNCTION set_updated_at() RETURNS trigger AS $$
        BEGIN NEW.updated_at = now(); RETURN NEW; END;
        $$ LANGUAGE plpgsql;
        CREATE OR REPLACE TRIGGER trg_products_updated_at BEFORE UPDATE ON products
            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
        CREATE OR REPLACE TRIGGER trg_variants_updated_at BEFORE UPDATE ON product_variants
            FOR EACH ROW EXECUTE FUNCTION set_updated_at();
        """;
}
