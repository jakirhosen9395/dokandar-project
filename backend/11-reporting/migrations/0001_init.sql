CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS fact_order (
  sub_order_id     uuid PRIMARY KEY,
  order_id         uuid NOT NULL,
  customer_id      uuid NOT NULL,
  shop_id          uuid NOT NULL,
  shopkeeper_id    uuid,
  state            varchar(20) NOT NULL,
  total_minor      int NOT NULL DEFAULT 0,
  placed_at        timestamptz NOT NULL,
  delivered_at     timestamptz,
  refunded_at      timestamptz,
  date_key         date NOT NULL,
  updated_at       timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_fact_order_date ON fact_order(date_key);
CREATE INDEX IF NOT EXISTS idx_fact_order_shop ON fact_order(shop_id, date_key);

CREATE TABLE IF NOT EXISTS fact_order_state_change (
  sub_order_id  uuid NOT NULL,
  to_state      varchar(20) NOT NULL,
  changed_at    timestamptz NOT NULL,
  PRIMARY KEY (sub_order_id, to_state, changed_at)
);

CREATE TABLE IF NOT EXISTS fact_payment (
  intent_id           uuid PRIMARY KEY,
  order_id            uuid NOT NULL,
  amount_minor        int NOT NULL,
  commission_minor    int NOT NULL DEFAULT 0,
  net_to_shopkeeper_minor int NOT NULL DEFAULT 0,
  provider            varchar(20) NOT NULL,
  settled_at          timestamptz NOT NULL,
  date_key            date NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_fact_payment_date ON fact_payment(date_key);
CREATE INDEX IF NOT EXISTS idx_fact_payment_provider ON fact_payment(provider, date_key);

CREATE TABLE IF NOT EXISTS fact_payout (
  payout_id     uuid PRIMARY KEY,
  shopkeeper_id uuid NOT NULL,
  amount_minor  int NOT NULL,
  state         varchar(20) NOT NULL,
  completed_at  timestamptz,
  date_key      date NOT NULL
);

CREATE TABLE IF NOT EXISTS consumer_offsets (
  topic           text NOT NULL,
  partition_id    int NOT NULL,
  last_offset     bigint NOT NULL,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (topic, partition_id)
);
