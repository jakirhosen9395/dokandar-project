class CreateShippingSchema < ActiveRecord::Migration[8.1]
  def up
    execute <<~SQL
      CREATE EXTENSION IF NOT EXISTS pgcrypto;

      CREATE TABLE IF NOT EXISTS shipments (
        id              uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        sub_order_id    uuid NOT NULL,
        courier_id      uuid,
        status          varchar(24) NOT NULL DEFAULT 'pending',
        address_tier    varchar(16),
        upazila_code    text,
        cod_amount_minor integer,
        idempotency_key varchar(120) NOT NULL UNIQUE,
        tracking_code   varchar(120),
        booked_at timestamptz, delivered_at timestamptz,
        created_at timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX IF NOT EXISTS idx_shipments_sub    ON shipments(sub_order_id);
      CREATE INDEX IF NOT EXISTS idx_shipments_status ON shipments(status);

      CREATE TABLE IF NOT EXISTS shipment_events (
        id bigserial PRIMARY KEY,
        shipment_id uuid NOT NULL REFERENCES shipments(id) ON DELETE CASCADE,
        from_status varchar(24), to_status varchar(24) NOT NULL,
        courier_raw jsonb, at timestamptz NOT NULL DEFAULT now()
      );

      CREATE TABLE IF NOT EXISTS couriers (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        name varchar(40) NOT NULL,
        active boolean NOT NULL DEFAULT true,
        supports_cod boolean NOT NULL DEFAULT true
      );

      CREATE TABLE IF NOT EXISTS courier_pricing_rules (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        courier_id uuid NOT NULL REFERENCES couriers(id),
        address_tier varchar(16) NOT NULL,
        base_minor integer NOT NULL, per_kg_minor integer NOT NULL,
        sla_hours integer NOT NULL, valid_from timestamptz NOT NULL DEFAULT now()
      );
      CREATE INDEX IF NOT EXISTS idx_pricing_tier ON courier_pricing_rules(address_tier);

      CREATE TABLE IF NOT EXISTS rural_agents (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        upazila_code text NOT NULL, name text NOT NULL, phone text,
        active boolean NOT NULL DEFAULT true
      );
      CREATE INDEX IF NOT EXISTS idx_rural_agents_upazila ON rural_agents(upazila_code) WHERE active;

      CREATE TABLE IF NOT EXISTS delivery_zones (
        id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
        upazila_code text NOT NULL UNIQUE,
        tier varchar(16) NOT NULL, fallback_distance_km numeric(6,1)
      );

      CREATE TABLE IF NOT EXISTS outbox (
        id bigserial PRIMARY KEY,
        topic varchar(120) NOT NULL, key varchar(120),
        payload jsonb NOT NULL,
        created_at timestamptz NOT NULL DEFAULT now(), sent_at timestamptz
      );
      CREATE INDEX IF NOT EXISTS idx_outbox_pending ON outbox(created_at) WHERE sent_at IS NULL;
    SQL
  end

  def down
    execute <<~SQL
      DROP TABLE IF EXISTS shipment_events, outbox, courier_pricing_rules, rural_agents,
        delivery_zones, shipments, couriers CASCADE;
    SQL
  end
end
