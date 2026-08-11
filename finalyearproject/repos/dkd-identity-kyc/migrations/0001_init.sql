-- Identity/Party/KYC schema (Context #1). Money-free; PII confined here (phone, nid_hash).
-- Raw NID is NEVER stored — only nid_hash = SHA-256(rawNID).

CREATE TABLE IF NOT EXISTS party (
    did         TEXT     PRIMARY KEY,                 -- did:dokandar:{uuid7}, immutable
    phone       TEXT     NOT NULL UNIQUE,             -- E.164 +880; unique (FR-IDN-003)
    nid_hash    TEXT     NULL,                        -- SHA-256(rawNID); raw NID never stored
    kyc_tier    SMALLINT NOT NULL DEFAULT 0,          -- 0=UNVERIFIED 1=BASIC 2=FULL 3=BUSINESS
    bin         TEXT     NULL,                         -- required for BUSINESS, <=15
    tin         TEXT     NULL,                         -- optional, <=12
    locale      TEXT     NOT NULL DEFAULT 'bn-BD',
    device_ids  TEXT[]   NOT NULL DEFAULT '{}',
    status      TEXT     NOT NULL DEFAULT 'ACTIVE',    -- ACTIVE|SUSPENDED|DELETED
    created_at  BIGINT   NOT NULL,
    updated_at  BIGINT   NOT NULL
);

-- Invariant: one NID binds to at most one verified (BASIC+) party (FR-IDN-026 / FR-ROL-052).
CREATE UNIQUE INDEX IF NOT EXISTS ux_party_nid_verified
    ON party (nid_hash) WHERE nid_hash IS NOT NULL AND kyc_tier >= 1;

-- Transactional outbox: state change + event committed in one local tx; a dispatcher publishes later.
CREATE TABLE IF NOT EXISTS outbox (
    id            BIGSERIAL PRIMARY KEY,
    event_id      UUID    NOT NULL UNIQUE,
    bus           TEXT    NOT NULL,                    -- 'kafka' | 'rabbitmq'
    destination   TEXT    NOT NULL,                    -- topic or queue name
    partition_key TEXT    NOT NULL,                    -- ordering key (DID)
    payload       JSONB   NOT NULL,
    headers       JSONB   NOT NULL,
    created_at    BIGINT  NOT NULL,
    sent_at       BIGINT  NULL,
    attempts      INT     NOT NULL DEFAULT 0
);

CREATE INDEX IF NOT EXISTS ix_outbox_unsent ON outbox (id) WHERE sent_at IS NULL;
