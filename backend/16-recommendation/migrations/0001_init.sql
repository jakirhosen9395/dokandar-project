CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS interaction_log (
  id          bigserial PRIMARY KEY,
  user_id     uuid,
  kind        text NOT NULL CHECK (kind IN ('view','click','add_to_cart','order','review','search')),
  product_id  uuid,
  shop_id     uuid,
  category_id uuid,
  district    text,
  occurred_at timestamptz NOT NULL DEFAULT now(),
  source_event_id text
);
CREATE INDEX IF NOT EXISTS interaction_user_time ON interaction_log(user_id, occurred_at DESC);
CREATE INDEX IF NOT EXISTS interaction_product ON interaction_log(product_id);
CREATE INDEX IF NOT EXISTS interaction_event_id ON interaction_log(source_event_id) WHERE source_event_id IS NOT NULL;

CREATE TABLE IF NOT EXISTS consumer_offsets (
  topic text NOT NULL,
  partition_id int NOT NULL,
  last_offset bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (topic, partition_id)
);

-- Popularity table — precomputed fallback for cold-start + Qdrant outage
CREATE TABLE IF NOT EXISTS popularity (
  product_id uuid PRIMARY KEY,
  score double precision NOT NULL DEFAULT 0,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_popularity_score ON popularity(score DESC);

-- Cross-sell — frequently-bought-together pairs
CREATE TABLE IF NOT EXISTS cross_sell (
  product_id uuid NOT NULL,
  paired_product_id uuid NOT NULL,
  weight double precision NOT NULL DEFAULT 0,
  PRIMARY KEY (product_id, paired_product_id)
);
