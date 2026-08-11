ALTER TABLE stock_movement ADD COLUMN IF NOT EXISTS posting_key TEXT;  -- INV-02: canon INV-<eventHash> hash-linked posting key
