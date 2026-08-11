-- Idempotency store for unsafe REST writes (Idempotency-Key header is mandatory on unsafe writes).
-- A successful response is recorded per key and replayed on retry, making POST commands safe to retry.
CREATE TABLE IF NOT EXISTS idempotency_keys (
    key             TEXT   PRIMARY KEY,
    method          TEXT   NOT NULL,
    path            TEXT   NOT NULL,
    response_status INT    NOT NULL,
    response_body   JSONB  NOT NULL,
    created_at      BIGINT NOT NULL
);
