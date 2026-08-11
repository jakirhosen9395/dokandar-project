-- 08-review schema (6 tables + outbox)
CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS reviews (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id         uuid NOT NULL,
  target_kind     varchar(16) NOT NULL CHECK (target_kind IN ('product','shop')),
  product_id      uuid,
  shop_id         uuid,
  order_id        uuid NOT NULL,
  rating          smallint NOT NULL CHECK (rating BETWEEN 1 AND 5),
  title           varchar(200),
  body            text,
  media_ids       uuid[] NOT NULL DEFAULT '{}',
  votes_helpful   int NOT NULL DEFAULT 0,
  votes_not       int NOT NULL DEFAULT 0,
  reports_count   int NOT NULL DEFAULT 0,
  status          varchar(12) NOT NULL DEFAULT 'visible' CHECK (status IN ('visible','hidden','removed')),
  created_at      timestamptz NOT NULL DEFAULT now(),
  updated_at      timestamptz NOT NULL DEFAULT now(),
  UNIQUE NULLS NOT DISTINCT (user_id, target_kind, product_id, shop_id, order_id)
);
CREATE INDEX IF NOT EXISTS idx_reviews_target ON reviews(target_kind, product_id, shop_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_reviews_user ON reviews(user_id, created_at DESC);

CREATE TABLE IF NOT EXISTS review_replies (
  review_id   uuid PRIMARY KEY REFERENCES reviews(id) ON DELETE CASCADE,
  shopkeeper_id uuid NOT NULL,
  body        text NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS review_votes (
  review_id  uuid NOT NULL REFERENCES reviews(id) ON DELETE CASCADE,
  user_id    uuid NOT NULL,
  is_helpful boolean NOT NULL,
  voted_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (review_id, user_id)
);

CREATE TABLE IF NOT EXISTS review_reports (
  review_id    uuid NOT NULL REFERENCES reviews(id) ON DELETE CASCADE,
  reporter_id  uuid NOT NULL,
  reason       varchar(20) NOT NULL CHECK (reason IN ('spam','hate','off_topic','pii','other')),
  reported_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (review_id, reporter_id)
);

CREATE TABLE IF NOT EXISTS rating_aggregates (
  target_kind varchar(16) NOT NULL,
  target_id   uuid NOT NULL,
  count       int NOT NULL DEFAULT 0,
  sum_rating  int NOT NULL DEFAULT 0,
  n1 int NOT NULL DEFAULT 0, n2 int NOT NULL DEFAULT 0,
  n3 int NOT NULL DEFAULT 0, n4 int NOT NULL DEFAULT 0, n5 int NOT NULL DEFAULT 0,
  updated_at  timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (target_kind, target_id)
);

CREATE TABLE IF NOT EXISTS purchase_eligibility (
  user_id    uuid NOT NULL,
  order_id   uuid NOT NULL,
  product_id uuid NOT NULL,
  shop_id    uuid,
  eligible   boolean NOT NULL DEFAULT true,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, order_id, product_id)
);
CREATE INDEX IF NOT EXISTS idx_eligibility_user ON purchase_eligibility(user_id);

CREATE TABLE IF NOT EXISTS outbox (
  id bigserial PRIMARY KEY,
  topic varchar(120) NOT NULL,
  key varchar(120),
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;

CREATE TABLE IF NOT EXISTS consumer_offsets (
  topic text NOT NULL,
  partition_id int NOT NULL,
  last_offset bigint NOT NULL,
  updated_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (topic, partition_id)
);
