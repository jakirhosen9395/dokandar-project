-- Idempotent event projection (architecture §10): a redelivered Kafka event (same
-- source_event_id) must NOT double-count into interaction_log / popularity. Replace the
-- non-unique partial index with a UNIQUE partial index so ingest_interaction can
-- `ON CONFLICT (source_event_id) DO NOTHING` and skip the popularity bump on a duplicate.
DROP INDEX IF EXISTS interaction_event_id;
CREATE UNIQUE INDEX IF NOT EXISTS interaction_event_id
  ON interaction_log(source_event_id) WHERE source_event_id IS NOT NULL;
