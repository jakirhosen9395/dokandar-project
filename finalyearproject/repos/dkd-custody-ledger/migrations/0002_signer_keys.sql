-- C3-F2: verify-side signer-key registry for the REAL Ed25519 dual custodial co-signature.
-- Holds PUBLIC keys ONLY — private keys never leave the signer and are NEVER stored here.
-- In production this is fed by the Identity-PKI Open-Host Service; a dev registration endpoint
-- (POST /v1/custody/signer-keys) seeds it locally. The key_id <-> bound_did binding is enforced
-- at co-sign time: a signature from a key not bound to the acting DID is rejected even if the
-- raw Ed25519 math verifies.
CREATE TABLE IF NOT EXISTS signer_keys (
    key_id     TEXT   PRIMARY KEY,
    public_key TEXT   NOT NULL,   -- base64-std 32-byte Ed25519 public key
    bound_did  TEXT   NOT NULL,   -- DID this key is authorized to sign for
    created_at BIGINT NOT NULL    -- unix-ms
);
CREATE INDEX IF NOT EXISTS signer_keys_bound_did_idx ON signer_keys (bound_did);
