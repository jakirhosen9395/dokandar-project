-- Profile service: schema + BD geo seed (single fresh version).
-- profiles.user_id mirrors auth.users.id — NO cross-service FK; consistency
-- is asynchronous via the dokandar.user.created Kafka event.

CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS cube;
CREATE EXTENSION IF NOT EXISTS earthdistance;

-- ============================================================
-- BD geo reference tables
-- ============================================================
CREATE TABLE bd_divisions (
    code        TEXT PRIMARY KEY,
    name_en     TEXT NOT NULL,
    name_bn     TEXT NOT NULL,
    sort_order  INT NOT NULL DEFAULT 0
);

CREATE TABLE bd_districts (
    code           TEXT PRIMARY KEY,
    division_code  TEXT NOT NULL REFERENCES bd_divisions(code),
    name_en        TEXT NOT NULL,
    name_bn        TEXT NOT NULL,
    sort_order     INT NOT NULL DEFAULT 0
);
CREATE INDEX bd_districts_division_idx ON bd_districts(division_code);

CREATE TABLE bd_upazilas (
    code           TEXT PRIMARY KEY,
    district_code  TEXT NOT NULL REFERENCES bd_districts(code),
    name_en        TEXT NOT NULL,
    name_bn        TEXT NOT NULL,
    sort_order     INT NOT NULL DEFAULT 0
);
CREATE INDEX bd_upazilas_district_idx ON bd_upazilas(district_code);

CREATE TABLE bd_unions (
    code         TEXT PRIMARY KEY,
    upazila_code TEXT NOT NULL REFERENCES bd_upazilas(code),
    name_en      TEXT NOT NULL,
    name_bn      TEXT NOT NULL,
    postal_code  TEXT,
    sort_order   INT NOT NULL DEFAULT 0
);
CREATE INDEX bd_unions_upazila_idx ON bd_unions(upazila_code);

-- ============================================================
-- Profiles (1:1 with auth.users.id)
-- kyc mirror matches auth.kyc enum:
--   (unverified | submitted | verified | rejected)
-- ============================================================
CREATE TABLE profiles (
    user_id            UUID PRIMARY KEY,
    phone              TEXT NOT NULL,
    email              TEXT,
    name_en            TEXT,
    name_bn            TEXT,
    gender             TEXT CHECK (gender IN ('m','f','x','prefer_not_say')),
    dob                DATE,
    locale             TEXT NOT NULL DEFAULT 'bn'
                            CHECK (locale IN ('bn','en')),
    avatar_media_id    UUID,
    default_address_id UUID,
    kyc                TEXT NOT NULL DEFAULT 'unverified'
                            CHECK (kyc IN ('unverified','submitted','verified','rejected')),
    whatsapp_number    TEXT,
    created_at         TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at         TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX profiles_phone_idx ON profiles(phone);

-- ============================================================
-- Addresses (customer address book)
-- ============================================================
CREATE TABLE addresses (
    id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    user_id         UUID NOT NULL REFERENCES profiles(user_id) ON DELETE CASCADE,
    label           TEXT NOT NULL,
    recipient_name  TEXT NOT NULL,
    recipient_phone TEXT NOT NULL CHECK (recipient_phone ~ '^01[3-9][0-9]{8}$'),

    division_code   TEXT NOT NULL REFERENCES bd_divisions(code),
    district_code   TEXT NOT NULL REFERENCES bd_districts(code),
    upazila_code    TEXT NOT NULL REFERENCES bd_upazilas(code),
    union_code      TEXT          REFERENCES bd_unions(code),

    line1           TEXT NOT NULL,
    line2           TEXT,
    landmark        TEXT,

    lat             DOUBLE PRECISION,
    lng             DOUBLE PRECISION,
    earth_loc       EARTH GENERATED ALWAYS AS (
                       CASE WHEN lat IS NOT NULL AND lng IS NOT NULL
                            THEN ll_to_earth(lat, lng) ELSE NULL END
                    ) STORED,

    is_default      BOOLEAN NOT NULL DEFAULT false,
    deleted_at      TIMESTAMPTZ,
    created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
    updated_at      TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX  addresses_user_idx      ON addresses(user_id) WHERE deleted_at IS NULL;
CREATE UNIQUE INDEX addresses_one_default
                                      ON addresses(user_id)
                                        WHERE is_default = true AND deleted_at IS NULL;
CREATE INDEX  addresses_geo_idx       ON addresses USING GIST(earth_loc) WHERE earth_loc IS NOT NULL;

-- ============================================================
-- Transactional outbox: written same-tx as the business change.
-- A relay loop publishes pending rows to Kafka, marks sent_at.
-- ============================================================
CREATE TABLE outbox (
    id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    aggregate_id  UUID NOT NULL,
    topic         TEXT NOT NULL,
    payload       JSONB NOT NULL,
    sent_at       TIMESTAMPTZ,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX outbox_pending_idx ON outbox(created_at) WHERE sent_at IS NULL;

-- ============================================================
-- BD geo seed — 8 divisions + representative districts/upazilas/unions
-- under Dhaka and Chittagong so the address-create happy path works
-- against a real FK chain. Production seeds the full ~4500-row dataset
-- separately (see data/bd-geo.sql for the loader contract).
-- ============================================================
INSERT INTO bd_divisions(code, name_en, name_bn, sort_order) VALUES
  ('barisal',    'Barisal',    'বরিশাল',    1),
  ('chittagong', 'Chittagong', 'চট্টগ্রাম', 2),
  ('dhaka',      'Dhaka',      'ঢাকা',      3),
  ('khulna',     'Khulna',     'খুলনা',     4),
  ('mymensingh', 'Mymensingh', 'ময়মনসিংহ',  5),
  ('rajshahi',   'Rajshahi',   'রাজশাহী',   6),
  ('rangpur',    'Rangpur',    'রংপুর',     7),
  ('sylhet',     'Sylhet',     'সিলেট',     8);

INSERT INTO bd_districts(code, division_code, name_en, name_bn, sort_order) VALUES
  -- Dhaka division
  ('dhaka',      'dhaka',      'Dhaka',      'ঢাকা',      1),
  ('gazipur',    'dhaka',      'Gazipur',    'গাজীপুর',   2),
  ('narayanganj','dhaka',      'Narayanganj','নারায়ণগঞ্জ',3),
  -- Chittagong division
  ('chittagong', 'chittagong', 'Chittagong', 'চট্টগ্রাম', 1),
  ('coxsbazar',  'chittagong', 'Cox''s Bazar','কক্সবাজার',2),
  -- Sylhet
  ('sylhet',     'sylhet',     'Sylhet',     'সিলেট',     1),
  -- Khulna
  ('khulna',     'khulna',     'Khulna',     'খুলনা',     1),
  -- Rajshahi
  ('rajshahi',   'rajshahi',   'Rajshahi',   'রাজশাহী',   1),
  -- Rangpur
  ('rangpur',    'rangpur',    'Rangpur',    'রংপুর',     1),
  -- Mymensingh
  ('mymensingh', 'mymensingh', 'Mymensingh', 'ময়মনসিংহ',  1),
  -- Barisal
  ('barisal',    'barisal',    'Barisal',    'বরিশাল',    1);

INSERT INTO bd_upazilas(code, district_code, name_en, name_bn, sort_order) VALUES
  -- Dhaka district
  ('dhanmondi',     'dhaka',      'Dhanmondi',     'ধানমন্ডি',     1),
  ('gulshan',       'dhaka',      'Gulshan',       'গুলশান',       2),
  ('mirpur',        'dhaka',      'Mirpur',        'মিরপুর',       3),
  ('motijheel',     'dhaka',      'Motijheel',     'মতিঝিল',       4),
  ('uttara',        'dhaka',      'Uttara',        'উত্তরা',       5),
  -- Gazipur district
  ('tongi',         'gazipur',    'Tongi',         'টঙ্গী',         1),
  ('gazipur-sadar', 'gazipur',    'Gazipur Sadar', 'গাজীপুর সদর',  2),
  -- Narayanganj district
  ('narayanganj-sadar','narayanganj','Narayanganj Sadar','নারায়ণগঞ্জ সদর',1),
  -- Chittagong district
  ('panchlaish',    'chittagong', 'Panchlaish',    'পাঁচলাইশ',     1),
  ('agrabad',       'chittagong', 'Agrabad',       'আগ্রাবাদ',     2),
  ('khulshi',       'chittagong', 'Khulshi',       'খুলশী',        3),
  -- Cox's Bazar district
  ('coxsbazar-sadar','coxsbazar', 'Cox''s Bazar Sadar','কক্সবাজার সদর',1),
  -- Sylhet
  ('sylhet-sadar',  'sylhet',     'Sylhet Sadar',  'সিলেট সদর',    1),
  -- Khulna
  ('khulna-sadar',  'khulna',     'Khulna Sadar',  'খুলনা সদর',    1),
  -- Rajshahi
  ('rajshahi-sadar','rajshahi',   'Rajshahi Sadar','রাজশাহী সদর',  1),
  -- Rangpur
  ('rangpur-sadar', 'rangpur',    'Rangpur Sadar', 'রংপুর সদর',    1),
  -- Mymensingh
  ('mymensingh-sadar','mymensingh','Mymensingh Sadar','ময়মনসিংহ সদর',1),
  -- Barisal
  ('barisal-sadar', 'barisal',    'Barisal Sadar', 'বরিশাল সদর',   1);

INSERT INTO bd_unions(code, upazila_code, name_en, name_bn, postal_code, sort_order) VALUES
  -- Dhaka / Dhanmondi
  ('dhanmondi-7',  'dhanmondi','Ward 7',  'ওয়ার্ড ৭',  '1205', 1),
  ('dhanmondi-15', 'dhanmondi','Ward 15', 'ওয়ার্ড ১৫', '1209', 2),
  -- Dhaka / Gulshan
  ('gulshan-1',    'gulshan',  'Gulshan 1','গুলশান ১',  '1212', 1),
  ('gulshan-2',    'gulshan',  'Gulshan 2','গুলশান ২',  '1212', 2),
  ('banani',       'gulshan',  'Banani',  'বনানী',     '1213', 3),
  -- Dhaka / Mirpur
  ('mirpur-10',    'mirpur',   'Mirpur 10','মিরপুর ১০', '1216', 1),
  ('mirpur-1',     'mirpur',   'Mirpur 1', 'মিরপুর ১',  '1216', 2),
  -- Dhaka / Motijheel
  ('motijheel-c','motijheel','Motijheel C/A','মতিঝিল বা/এ','1000', 1),
  -- Dhaka / Uttara
  ('uttara-sector-7','uttara','Sector 7','সেক্টর ৭','1230', 1),
  -- Chittagong / Panchlaish
  ('panchlaish-1','panchlaish','Ward 1','ওয়ার্ড ১','4203', 1),
  -- Chittagong / Agrabad
  ('agrabad-c','agrabad','Agrabad C/A','আগ্রাবাদ বা/এ','4100', 1),
  -- Cox's Bazar Sadar
  ('coxsbazar-1','coxsbazar-sadar','Ward 1','ওয়ার্ড ১','4700', 1),
  -- Sylhet
  ('sylhet-1','sylhet-sadar','Ward 1','ওয়ার্ড ১','3100', 1),
  -- Khulna
  ('khulna-1','khulna-sadar','Ward 1','ওয়ার্ড ১','9100', 1),
  -- Rajshahi
  ('rajshahi-1','rajshahi-sadar','Ward 1','ওয়ার্ড ১','6000', 1),
  -- Rangpur
  ('rangpur-1','rangpur-sadar','Ward 1','ওয়ার্ড ১','5400', 1),
  -- Mymensingh
  ('mymensingh-1','mymensingh-sadar','Ward 1','ওয়ার্ড ১','2200', 1),
  -- Barisal
  ('barisal-1','barisal-sadar','Ward 1','ওয়ার্ড ১','8200', 1);
