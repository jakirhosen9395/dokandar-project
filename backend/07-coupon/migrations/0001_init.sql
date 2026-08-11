-- 07-coupon — discount engine schema.
-- Five tables: coupons, coupon_redemptions, festivals, festival_shops, outbox.
-- VARCHAR + CHECK over PG ENUMs (avoids the asyncpg/Npgsql enum-mapping
-- fragility called out in architecture §16-i / §3.1).

CREATE EXTENSION IF NOT EXISTS pgcrypto;   -- gen_random_uuid()

CREATE TABLE IF NOT EXISTS coupons (
  id                  uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  code                varchar(40) NOT NULL UNIQUE,
  kind                varchar(20) NOT NULL
                      CHECK (kind IN ('percent','fixed','free_delivery','min_spend','first_order')),
  scope               varchar(10) NOT NULL CHECK (scope IN ('shop','platform')),
  funded_by           varchar(12) NOT NULL CHECK (funded_by IN ('shopkeeper','platform')),
  shop_id             uuid,
  value_percent       smallint CHECK (value_percent IS NULL OR (value_percent >= 1 AND value_percent <= 90)),
  value_minor         int CHECK (value_minor IS NULL OR value_minor > 0),
  max_discount_minor  int CHECK (max_discount_minor IS NULL OR max_discount_minor > 0),
  min_spend_minor     int CHECK (min_spend_minor IS NULL OR min_spend_minor >= 0),
  valid_from          timestamptz NOT NULL,
  valid_until         timestamptz NOT NULL,
  max_redemptions     int CHECK (max_redemptions IS NULL OR max_redemptions > 0),
  max_per_user        int NOT NULL DEFAULT 1 CHECK (max_per_user >= 1),
  drafted_by          uuid NOT NULL,
  approved_by         uuid,
  state               varchar(12) NOT NULL DEFAULT 'draft'
                      CHECK (state IN ('draft','approved','active','expired','revoked')),
  created_at          timestamptz NOT NULL DEFAULT now(),
  updated_at          timestamptz NOT NULL DEFAULT now(),
  CHECK (
    (scope = 'shop' AND shop_id IS NOT NULL)
    OR (scope = 'platform' AND shop_id IS NULL)
  ),
  CHECK (valid_until > valid_from)
);
CREATE INDEX IF NOT EXISTS idx_coupons_shop_state ON coupons(shop_id, state);
CREATE INDEX IF NOT EXISTS idx_coupons_state_window ON coupons(state, valid_from, valid_until);

CREATE TABLE IF NOT EXISTS coupon_redemptions (
  id            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  coupon_id     uuid NOT NULL REFERENCES coupons(id) ON DELETE CASCADE,
  user_id       uuid NOT NULL,
  order_id      uuid NOT NULL,
  sub_order_id  uuid,
  amount_minor  int NOT NULL CHECK (amount_minor >= 0),
  redeemed_at   timestamptz NOT NULL DEFAULT now(),
  UNIQUE (coupon_id, order_id)
);
CREATE INDEX IF NOT EXISTS idx_redemptions_user ON coupon_redemptions(coupon_id, user_id);

CREATE TABLE IF NOT EXISTS festivals (
  id                            uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  slug                          varchar(40) NOT NULL UNIQUE,
  name_bn                       varchar(120) NOT NULL,
  name_en                       varchar(120) NOT NULL,
  starts_at                     timestamptz NOT NULL,
  ends_at                       timestamptz NOT NULL,
  banner_s3_key                 varchar(255),
  template_kind                 varchar(20) NOT NULL
                                CHECK (template_kind IN ('percent','fixed','free_delivery','min_spend','first_order')),
  template_value_percent        smallint CHECK (template_value_percent IS NULL OR (template_value_percent >= 1 AND template_value_percent <= 90)),
  template_value_minor          int CHECK (template_value_minor IS NULL OR template_value_minor > 0),
  template_max_discount_minor   int,
  funded_by_default             varchar(12) NOT NULL DEFAULT 'shopkeeper' CHECK (funded_by_default IN ('shopkeeper','platform')),
  created_by                    uuid NOT NULL,
  created_at                    timestamptz NOT NULL DEFAULT now(),
  CHECK (ends_at > starts_at)
);
CREATE INDEX IF NOT EXISTS idx_festivals_window ON festivals(starts_at, ends_at);

CREATE TABLE IF NOT EXISTS festival_shops (
  id                     uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  festival_id            uuid NOT NULL REFERENCES festivals(id) ON DELETE CASCADE,
  shop_id                uuid NOT NULL,
  opted_in_at            timestamptz NOT NULL DEFAULT now(),
  override_value_percent smallint CHECK (override_value_percent IS NULL OR (override_value_percent >= 1 AND override_value_percent <= 90)),
  override_value_minor   int CHECK (override_value_minor IS NULL OR override_value_minor > 0),
  UNIQUE (festival_id, shop_id)
);

CREATE TABLE IF NOT EXISTS outbox (
  id          bigserial PRIMARY KEY,
  topic       varchar(120) NOT NULL,
  key         varchar(120),
  payload     jsonb NOT NULL,
  created_at  timestamptz NOT NULL DEFAULT now(),
  sent_at     timestamptz
);
CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;
