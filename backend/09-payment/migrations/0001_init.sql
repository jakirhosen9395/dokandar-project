CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS payment_intents (
  id                    uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  order_id              uuid NOT NULL UNIQUE,
  customer_id           uuid NOT NULL,
  shopkeeper_id         uuid,
  provider              varchar(20) NOT NULL CHECK (provider IN ('bkash','nagad','rocket','sslcommerz','stripe','bank_transfer','wallet','cod')),
  amount_minor          int NOT NULL CHECK (amount_minor >= 0),
  currency              char(3) NOT NULL DEFAULT 'BDT',
  state                 varchar(20) NOT NULL DEFAULT 'created' CHECK (state IN ('created','pending','settled','failed','cancelled','refunded','cod_pending')),
  provider_intent_id    varchar(120),
  provider_redirect_url varchar(2048),
  card_last4            varchar(4),
  card_brand            varchar(20),
  card_tokenized_id     varchar(120),
  idempotency_key       varchar(120) NOT NULL UNIQUE,
  created_at            timestamptz NOT NULL DEFAULT now(),
  settled_at            timestamptz
);
CREATE INDEX IF NOT EXISTS idx_intents_state ON payment_intents(state) WHERE state IN ('pending','cod_pending');

CREATE TABLE IF NOT EXISTS payments (
  id                      uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  intent_id               uuid NOT NULL UNIQUE REFERENCES payment_intents(id),
  provider_txn_id         varchar(120) NOT NULL,
  amount_minor            int NOT NULL,
  commission_minor        int NOT NULL,
  net_to_shopkeeper_minor int NOT NULL,
  paid_out                boolean NOT NULL DEFAULT false,
  settled_at              timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_payments_unpaid ON payments(paid_out) WHERE paid_out = false;

CREATE TABLE IF NOT EXISTS payment_webhooks (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  provider     varchar(20) NOT NULL,
  event_id     varchar(120) NOT NULL,
  raw_body     text NOT NULL,
  signature_ok boolean NOT NULL,
  processed_at timestamptz,
  received_at  timestamptz NOT NULL DEFAULT now(),
  UNIQUE (provider, event_id)
);

CREATE TABLE IF NOT EXISTS payouts (
  id                 uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  shopkeeper_id      uuid NOT NULL,
  tier               varchar(20) NOT NULL DEFAULT 'held_3day',
  amount_minor       int NOT NULL CHECK (amount_minor >= 0),
  payment_intent_ids text NOT NULL,
  method             varchar(20) NOT NULL DEFAULT 'bank_transfer',
  destination        text NOT NULL,
  state              varchar(20) NOT NULL DEFAULT 'pending' CHECK (state IN ('pending','enqueued','succeeded','failed')),
  attempts           int NOT NULL DEFAULT 0,
  provider_txn_id    varchar(120),
  created_at         timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS payout_attempts (
  id bigserial PRIMARY KEY,
  payout_id uuid NOT NULL REFERENCES payouts(id) ON DELETE CASCADE,
  attempt_no int NOT NULL,
  state varchar(20) NOT NULL,
  error text,
  attempted_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS cod_ledger (
  id bigserial PRIMARY KEY,
  shopkeeper_id uuid NOT NULL,
  order_id uuid NOT NULL,
  commission_owed_minor int NOT NULL,
  settled_via_payout_id uuid REFERENCES payouts(id),
  settled_via_invoice_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS commission_rates (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  scope varchar(20) NOT NULL CHECK (scope IN ('platform_default','category','shopkeeper')),
  scope_id uuid,
  percent_basis_points int NOT NULL CHECK (percent_basis_points >= 0 AND percent_basis_points <= 10000),
  flat_minor int NOT NULL DEFAULT 0,
  valid_from timestamptz NOT NULL DEFAULT now(),
  valid_until timestamptz,
  created_by uuid NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
-- seed platform default 2.5%
INSERT INTO commission_rates (scope, percent_basis_points, created_by)
  SELECT 'platform_default', 250, '00000000-0000-0000-0000-000000000000'::uuid
  WHERE NOT EXISTS (SELECT 1 FROM commission_rates WHERE scope = 'platform_default');

CREATE TABLE IF NOT EXISTS commission_reversals (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  payment_id uuid NOT NULL REFERENCES payments(id),
  refunded_amount_minor int NOT NULL,
  reversed_commission_minor int NOT NULL,
  return_id uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS outbox (
  id bigserial PRIMARY KEY,
  topic varchar(120) NOT NULL,
  key varchar(120),
  payload jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at timestamptz
);
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;
