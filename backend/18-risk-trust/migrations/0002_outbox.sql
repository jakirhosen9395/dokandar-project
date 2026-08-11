-- Transactional outbox (§10) — 18-risk-trust EMITS dokandar.risk.* decisions. The relay
-- polls `WHERE sent_at IS NULL FOR UPDATE SKIP LOCKED`. risk_outbox_pending is mandatory.
CREATE TABLE IF NOT EXISTS outbox (
  id          bigserial PRIMARY KEY,
  topic       varchar(120) NOT NULL,
  key         varchar(120),
  payload     jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz
);
CREATE INDEX IF NOT EXISTS idx_risk_outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;

CREATE TABLE IF NOT EXISTS consumer_offsets (
  topic        text NOT NULL,
  partition_id int NOT NULL,
  last_offset  bigint NOT NULL,
  updated_at   timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (topic, partition_id)
);
