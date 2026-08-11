-- ID-02: persist the request-body hash alongside the idempotency key so a key REUSED with a
-- DIFFERENT body is rejected (409), instead of silently replaying the first request's response.
ALTER TABLE idempotency_keys ADD COLUMN IF NOT EXISTS request_hash TEXT;
