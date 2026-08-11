CREATE EXTENSION IF NOT EXISTS pgcrypto;

CREATE TABLE IF NOT EXISTS risk_rules (
  id          uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  name        text NOT NULL UNIQUE,
  signal      text NOT NULL CHECK (signal IN ('velocity','device','geo','bin_mismatch','cod_refusal','review_abuse')),
  threshold   jsonb NOT NULL,
  action      text NOT NULL CHECK (action IN ('allow','review','deny')),
  active      boolean NOT NULL DEFAULT true,
  created_by  uuid NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_risk_rules_active ON risk_rules(active) WHERE active;

CREATE TABLE IF NOT EXISTS risk_overrides (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type  text NOT NULL CHECK (entity_type IN ('user','order','shop','review')),
  entity_id    uuid NOT NULL,
  action       text NOT NULL CHECK (action IN ('allow','deny')),
  reason       text NOT NULL,
  expires_at   timestamptz,
  created_by   uuid NOT NULL,
  created_at   timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_risk_overrides_entity ON risk_overrides(entity_type, entity_id);

CREATE TABLE IF NOT EXISTS risk_decisions (
  id           uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  entity_type  text NOT NULL,
  entity_id    uuid NOT NULL,
  decision     text NOT NULL CHECK (decision IN ('allow','review','deny')),
  score        double precision NOT NULL,
  reason_codes text[] NOT NULL DEFAULT '{}',
  scored_at    timestamptz NOT NULL DEFAULT now(),
  UNIQUE (entity_type, entity_id)
);
CREATE INDEX IF NOT EXISTS idx_risk_decisions_scored ON risk_decisions(scored_at DESC);

-- COD-refusal history (proxy for ScyllaDB user_events when Scylla unavailable)
CREATE TABLE IF NOT EXISTS cod_refusals (
  id          bigserial PRIMARY KEY,
  user_id     uuid NOT NULL,
  order_id    uuid NOT NULL,
  refused_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS idx_cod_refusals_user ON cod_refusals(user_id);

-- seed a default rule: high velocity → review
INSERT INTO risk_rules (name, signal, threshold, action, created_by)
  SELECT 'velocity_high_orders_1h', 'velocity', '{"window":"1h","max_orders":10}'::jsonb, 'review',
         '00000000-0000-0000-0000-000000000000'::uuid
  WHERE NOT EXISTS (SELECT 1 FROM risk_rules WHERE name = 'velocity_high_orders_1h');
INSERT INTO risk_rules (name, signal, threshold, action, created_by)
  SELECT 'cod_refusal_3', 'cod_refusal', '{"max_refusals":3}'::jsonb, 'deny',
         '00000000-0000-0000-0000-000000000000'::uuid
  WHERE NOT EXISTS (SELECT 1 FROM risk_rules WHERE name = 'cod_refusal_3');
