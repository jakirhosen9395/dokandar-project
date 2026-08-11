-- 05-search projection store (architecture.md §3). All columns projected from
-- Kafka events; none authoritative. Idempotent (IF NOT EXISTS) — applied on boot.
CREATE EXTENSION IF NOT EXISTS pg_trgm;
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance;

CREATE TABLE IF NOT EXISTS products_view (
  product_id       uuid PRIMARY KEY,
  shop_id          uuid,
  shop_ids         uuid[] NOT NULL DEFAULT '{}',
  owner_id         uuid,
  sharing_model    text NOT NULL DEFAULT 'shared',
  category_id      uuid,
  name_en          text NOT NULL DEFAULT '',
  name_bn          text NOT NULL DEFAULT '',
  slug             text,
  list_price_minor int NOT NULL DEFAULT 0,
  sale_price_minor int,
  rating_avg       numeric(3,2) DEFAULT 0,
  rating_count     int DEFAULT 0,
  in_stock         boolean NOT NULL DEFAULT true,
  is_active        boolean NOT NULL DEFAULT true,
  tsv_en TSVECTOR GENERATED ALWAYS AS (setweight(to_tsvector('english', coalesce(name_en,'')),'A')) STORED,
  tsv_bn TSVECTOR GENERATED ALWAYS AS (setweight(to_tsvector('simple',  coalesce(name_bn,'')),'A')) STORED,
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS products_view_tsv_en       ON products_view USING GIN(tsv_en);
CREATE INDEX IF NOT EXISTS products_view_tsv_bn       ON products_view USING GIN(tsv_bn);
CREATE INDEX IF NOT EXISTS products_view_name_en_trgm ON products_view USING GIN(name_en gin_trgm_ops);
CREATE INDEX IF NOT EXISTS products_view_name_bn_trgm ON products_view USING GIN(name_bn gin_trgm_ops);
CREATE INDEX IF NOT EXISTS products_view_price        ON products_view(coalesce(sale_price_minor, list_price_minor));
CREATE INDEX IF NOT EXISTS products_view_active       ON products_view(is_active) WHERE is_active = true;

CREATE TABLE IF NOT EXISTS product_variants_view (
  variant_id uuid PRIMARY KEY,
  product_id uuid NOT NULL REFERENCES products_view(product_id) ON DELETE CASCADE,
  sku text, list_price_minor int, available_qty int NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS shops_view (
  shop_id       uuid PRIMARY KEY,
  owner_id      uuid,
  handle        text UNIQUE NOT NULL,
  name_en       text NOT NULL DEFAULT '',
  name_bn       text NOT NULL DEFAULT '',
  description   text,
  category_id   uuid,
  division_code text, district_code text, upazila_code text, union_code text,
  lat double precision, lng double precision,
  earth_loc EARTH GENERATED ALWAYS AS (ll_to_earth(lat, lng)) STORED,
  open_now     boolean NOT NULL DEFAULT true,
  rating_avg   numeric(3,2) DEFAULT 0, rating_count int DEFAULT 0,
  is_active    boolean NOT NULL DEFAULT true,
  tsv_en TSVECTOR GENERATED ALWAYS AS (
            setweight(to_tsvector('english', coalesce(name_en,'')),'A') ||
            setweight(to_tsvector('english', coalesce(description,'')),'B')) STORED,
  tsv_bn TSVECTOR GENERATED ALWAYS AS (setweight(to_tsvector('simple', coalesce(name_bn,'')),'A')) STORED,
  updated_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS shops_view_earth_loc ON shops_view USING GIST(earth_loc);
CREATE INDEX IF NOT EXISTS shops_view_tsv_en    ON shops_view USING GIN(tsv_en);

CREATE TABLE IF NOT EXISTS categories_view (
  category_id uuid PRIMARY KEY, parent_id uuid,
  name_en text NOT NULL DEFAULT '', name_bn text NOT NULL DEFAULT '',
  slug text, sort_order int, is_active boolean NOT NULL DEFAULT true, path text
);
CREATE INDEX IF NOT EXISTS categories_view_parent ON categories_view(parent_id);

CREATE TABLE IF NOT EXISTS trending_counters (
  product_id uuid NOT NULL, bucket_date date NOT NULL, order_count int NOT NULL DEFAULT 0,
  PRIMARY KEY (product_id, bucket_date)
);

CREATE TABLE IF NOT EXISTS query_logs (
  id bigserial PRIMARY KEY, user_id uuid,
  kind text NOT NULL DEFAULT 'products',
  locale text NOT NULL CHECK (locale IN ('bn','en')),
  raw_q text NOT NULL, result_count int NOT NULL,
  duration_ms numeric(8,2) NOT NULL, occurred_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS consumer_offsets (
  topic text NOT NULL, partition_id int NOT NULL, last_offset bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (topic, partition_id)
);
