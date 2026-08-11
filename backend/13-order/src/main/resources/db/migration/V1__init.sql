-- DOKANDAR 13-order — initial schema (architecture.md / spec §2).
-- Database: dokandar_order_<env>. Money is integer minor units (paisa) everywhere.
-- Cross-service references are opaque UUIDs — NO foreign keys across service boundaries.
-- Flyway owns this schema (applied once). DbBootstrap creates the DB then runs migrate().

CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE orders (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  customer_id       uuid NOT NULL,
  idempotency_key   varchar(120) UNIQUE,          -- the POST /orders dedup fence
  grand_total_minor int  NOT NULL CHECK (grand_total_minor >= 0),
  currency          varchar(3) NOT NULL DEFAULT 'BDT',
  created_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_orders_customer ON orders(customer_id, created_at DESC);

CREATE TABLE sub_orders (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id        uuid NOT NULL REFERENCES orders(id) ON DELETE CASCADE,
  shop_id         uuid NOT NULL,                   -- one sub-order per shop
  status          varchar(32) NOT NULL DEFAULT 'placed'
    CHECK (status IN ('placed','confirmed','packed','shipped','ready_for_pickup',
                      'delivered','picked_up','completed','cancelled','returned')),
  payment_state   varchar(16) NOT NULL DEFAULT 'pending'
    CHECK (payment_state IN ('pending','settled','failed','refunded')),
  delivery_method varchar(16) NOT NULL DEFAULT 'delivery'
    CHECK (delivery_method IN ('delivery','pickup')),
  shop_total_minor int NOT NULL CHECK (shop_total_minor >= 0),
  confirmed_at    timestamptz,
  created_at      timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_sub_orders_order ON sub_orders(order_id);
CREATE INDEX idx_sub_orders_shop  ON sub_orders(shop_id, status);

CREATE TABLE order_lines (
  id               uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sub_order_id     uuid NOT NULL REFERENCES sub_orders(id) ON DELETE CASCADE,
  product_id       uuid NOT NULL,
  variant_id       uuid NOT NULL,
  quantity         int  NOT NULL CHECK (quantity > 0),
  unit_price_minor int  NOT NULL CHECK (unit_price_minor >= 0),
  sale_price_minor int,                            -- nullable: discounted unit price
  line_total_minor int  NOT NULL CHECK (line_total_minor >= 0)
);
CREATE INDEX idx_order_lines_sub ON order_lines(sub_order_id);

CREATE TABLE order_status_history (              -- append-only audit
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  sub_order_id uuid NOT NULL REFERENCES sub_orders(id) ON DELETE CASCADE,
  from_status  varchar(32),
  to_status    varchar(32) NOT NULL,
  at           timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX idx_status_history_sub ON order_status_history(sub_order_id, at);

CREATE TABLE outbox (                            -- transactional outbox
  id         bigserial PRIMARY KEY,
  topic      varchar(120) NOT NULL,
  key        varchar(120),                       -- = order_id / sub_order_id (partition key)
  payload    jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at    timestamptz
);
CREATE INDEX idx_outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;  -- partial index for the relay
