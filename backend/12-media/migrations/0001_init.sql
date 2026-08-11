-- 12-media — dokandar_media_<env> schema (architecture.md §3.1 verbatim names + task extensions).
-- This file is executed in full on EVERY boot via sqlx::raw_sql (simple protocol, multi-statement),
-- so every statement MUST be idempotent (IF NOT EXISTS). Bare CREATE TABLE would fail on the 2nd boot.
CREATE EXTENSION IF NOT EXISTS pgcrypto;

-- ── media_objects: the row store + upload-lifecycle state machine ───────────────────────────────
CREATE TABLE IF NOT EXISTS media_objects (
  id                uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  owner_id          uuid NOT NULL,                  -- opaque user id from JWT sub (no cross-service FK)
  scope             text NOT NULL
                    CHECK (scope IN ('profile_avatar','shop_logo','shop_banner',
                                     'product_image','review_photo','kyc_doc','pod_photo','generic')),
  kind              text NOT NULL,                  -- free-form sub-type tag (e.g. 'nid','selfie','tin')
  mime              text NOT NULL,                  -- e.g. image/jpeg, application/pdf
  bytes             bigint,                         -- set at /complete via HeadObject
  sha256            text,                           -- client-declared, verified at complete
  bucket            text NOT NULL,
  object_key        text NOT NULL UNIQUE,           -- the S3 key; UNIQUE prevents collisions/overwrites
  width             int,                            -- EXTENSION: populated post-thumbnail (nullable)
  height            int,                            -- EXTENSION: populated post-thumbnail (nullable)
  state             text NOT NULL DEFAULT 'pending'
                    CHECK (state IN ('pending','uploaded','scanned','ready','quarantined','deleted')),
  av_clean          boolean,                        -- NULL until scanned; true=clean, false=infected
  derivatives_ready boolean NOT NULL DEFAULT false,
  soft_deleted_at   timestamptz,                    -- soft-delete; bucket lifecycle expires the object
  created_at        timestamptz NOT NULL DEFAULT now(),
  updated_at        timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS media_owner_idx        ON media_objects(owner_id);            -- "list mine"
CREATE INDEX IF NOT EXISTS media_owner_state_idx  ON media_objects(owner_id, state);     -- EXTENSION: list-mine filtered
CREATE INDEX IF NOT EXISTS media_state_idx        ON media_objects(state);
CREATE INDEX IF NOT EXISTS media_scope_idx        ON media_objects(scope);
CREATE INDEX IF NOT EXISTS media_soft_deleted_idx ON media_objects(soft_deleted_at) WHERE soft_deleted_at IS NOT NULL;

-- ── media_derivatives: thumbnails / resized variants (one row per (asset, label)) ───────────────
CREATE TABLE IF NOT EXISTS media_derivatives (
  media_id   uuid NOT NULL REFERENCES media_objects(id) ON DELETE CASCADE,
  label      text NOT NULL CHECK (label IN ('thumb','medium','large')),
  object_key text NOT NULL,
  width      int,
  height     int,
  bytes      bigint,
  PRIMARY KEY (media_id, label)
);

-- ── av_scan_results: EXTENSION — explicit AV scan history (spec folds verdict into av_clean) ─────
CREATE TABLE IF NOT EXISTS av_scan_results (
  id         bigserial PRIMARY KEY,
  media_id   uuid NOT NULL REFERENCES media_objects(id) ON DELETE CASCADE,
  verdict    text NOT NULL CHECK (verdict IN ('clean','infected','error')),
  engine     text NOT NULL,                         -- e.g. 'clamav-1.4' or 'stub'
  signature  text,                                  -- malware name when infected (nullable)
  scanned_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS av_scan_media_idx ON av_scan_results(media_id);

-- ── media_grants: per-user share grants (KYC docs are admin/owner-only unless granted) ──────────
CREATE TABLE IF NOT EXISTS media_grants (
  media_id   uuid NOT NULL REFERENCES media_objects(id) ON DELETE CASCADE,
  grantee_id uuid NOT NULL,
  granted_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (media_id, grantee_id)
);

-- ── outbox: transactional outbox (business row + outbox row in ONE tx; relay FOR UPDATE SKIP LOCKED) ──
CREATE TABLE IF NOT EXISTS outbox (
  id         bigserial PRIMARY KEY,
  topic      varchar(120) NOT NULL,
  key        varchar(120),                          -- = media_id (Kafka partition key)
  payload    jsonb NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  sent_at    timestamptz
);
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;  -- the relay's hot path
