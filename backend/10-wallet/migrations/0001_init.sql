CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS wallets (
  user_id    uuid PRIMARY KEY,
  currency   char(3) NOT NULL DEFAULT 'BDT',
  status     varchar(20) NOT NULL DEFAULT 'active' CHECK (status IN ('active','frozen','closed')),
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS wallet_entries (
  id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  wallet_user_id  uuid NOT NULL,
  debit_minor     int NOT NULL DEFAULT 0,
  credit_minor    int NOT NULL DEFAULT 0,
  kind            varchar(40) NOT NULL,
  order_id        uuid,
  sub_order_id    uuid,
  payment_intent_id uuid,
  expires_at      timestamptz,
  idempotency_key varchar(120) NOT NULL UNIQUE,
  posted_at       timestamptz NOT NULL DEFAULT now(),
  CHECK ((debit_minor > 0) <> (credit_minor > 0))
);
CREATE INDEX IF NOT EXISTS idx_entries_user_posted ON wallet_entries(wallet_user_id, posted_at DESC);

CREATE TABLE IF NOT EXISTS wallet_balances (
  user_id         uuid PRIMARY KEY,
  balance_minor   int NOT NULL DEFAULT 0,
  available_minor int NOT NULL DEFAULT 0,
  version         int NOT NULL DEFAULT 0,
  updated_at      timestamptz NOT NULL DEFAULT now(),
  CHECK (balance_minor BETWEEN 0 AND 5000000)
);

CREATE TABLE IF NOT EXISTS cashback_rules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  trigger    varchar(40) NOT NULL,
  funded_by  varchar(12) NOT NULL,
  reward_kind varchar(20) NOT NULL,
  reward_value int NOT NULL,
  reward_cap_minor int,
  min_subtotal_minor int,
  max_per_user int NOT NULL DEFAULT 1,
  active_from timestamptz NOT NULL DEFAULT now(),
  active_until timestamptz,
  state varchar(20) NOT NULL DEFAULT 'active',
  created_at timestamptz NOT NULL DEFAULT now()
);

INSERT INTO cashback_rules (trigger, funded_by, reward_kind, reward_value, reward_cap_minor, min_subtotal_minor, max_per_user)
  SELECT 'subtotal_threshold', 'platform', 'percent_back', 2, 50000, 100000, 5
  WHERE NOT EXISTS (SELECT 1 FROM cashback_rules WHERE trigger = 'subtotal_threshold');

CREATE TABLE IF NOT EXISTS cashback_grants (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  user_id uuid NOT NULL,
  rule_id uuid NOT NULL,
  order_id uuid NOT NULL,
  amount_minor int NOT NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, rule_id, order_id)
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
