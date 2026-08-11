# Idempotent seed: the five couriers + the rural-agent network + per-tier pricing rules +
# a few delivery zones. Re-runnable on every boot (find_or_create_by!).

TIERS = %w[city district upazila union].freeze

# base_minor / per_kg_minor / sla_hours per courier per tier (paisa). Cheaper + faster in
# the city; the rural_agent network covers upazila/union where the carriers don't reach.
COURIER_RULES = {
  "pathao"     => { supports_cod: true,  city: [6000, 1500, 24],  district: [9000, 2000, 48],  upazila: [13000, 2500, 72], union: [16000, 3000, 96] },
  "paperfly"   => { supports_cod: true,  city: [6500, 1400, 30],  district: [9500, 1900, 54],  upazila: [12500, 2400, 78], union: [15500, 2900, 100] },
  "redx"       => { supports_cod: true,  city: [5500, 1600, 26],  district: [8800, 2100, 50],  upazila: [13500, 2600, 74], union: [17000, 3100, 98] },
  "sundarban"  => { supports_cod: true,  city: [7000, 1300, 36],  district: [9200, 1800, 60],  upazila: [11800, 2300, 84], union: [14800, 2800, 108] },
  "ecourier"   => { supports_cod: true,  city: [6200, 1450, 28],  district: [9100, 1950, 52],  upazila: [13200, 2550, 76], union: [16500, 3050, 99] },
  "rural_agent" => { supports_cod: true, city: [9000, 2000, 48],  district: [10000, 2200, 72], upazila: [9500, 1800, 60],  union: [10500, 2000, 72] },
}.freeze

COURIER_RULES.each do |name, cfg|
  courier = Courier.find_or_create_by!(name: name) { |c| c.active = true; c.supports_cod = cfg[:supports_cod] }
  TIERS.each do |tier|
    base, per_kg, sla = cfg[tier.to_sym]
    next unless base
    unless CourierPricingRule.exists?(courier_id: courier.id, address_tier: tier)
      CourierPricingRule.create!(courier: courier, address_tier: tier,
                                 base_minor: base, per_kg_minor: per_kg, sla_hours: sla)
    end
  end
end

# A couple of delivery zones (upazila → tier + a straight-line fallback distance used when
# Neo4j is unavailable). Real data is loaded from the BD admin hierarchy out of band.
[
  ["dhaka_kotwali", "city", 8.0],
  ["savar", "district", 28.5],
  ["dhamrai", "upazila", 47.0],
  ["nagarpur", "union", 92.0],
].each do |code, tier, km|
  DeliveryZone.find_or_create_by!(upazila_code: code) { |z| z.tier = tier; z.fallback_distance_km = km }
end

RuralAgent.find_or_create_by!(upazila_code: "dhamrai", name: "Dhamrai Agent Hub") { |a| a.phone = "01710000000"; a.active = true }
RuralAgent.find_or_create_by!(upazila_code: "nagarpur", name: "Nagarpur Agent Hub") { |a| a.phone = "01710000001"; a.active = true }
