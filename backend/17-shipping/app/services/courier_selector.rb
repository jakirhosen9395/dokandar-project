# Courier selection by cost / SLA / address-tier across the five carriers + the rural-agent
# fallback (§1, §4.1). Returns an ordered candidate list (cheapest first) so booking can
# fail over to the next-best courier when one rejects.
module CourierSelector
  module_function

  DEFAULT_TIER = "district".freeze

  # Ordered [{courier:, fee_minor:, eta_hours:}] for the tier, cheapest first. COD-required
  # filters to supports_cod couriers. Empty if no pricing rules exist for the tier.
  def candidates(address_tier:, weight_grams:, cod_required: true)
    tier = valid_tier(address_tier)
    kg = [(weight_grams.to_i / 1000.0), 0.5].max
    rules = CourierPricingRule
              .where(address_tier: tier)
              .joins(:courier).where(couriers: { active: true })
    rules = rules.where(couriers: { supports_cod: true }) if cod_required
    rules.map { |r|
      { courier: r.courier.name,
        courier_id: r.courier_id,
        fee_minor: (r.base_minor + (r.per_kg_minor * kg).ceil).to_i,
        eta_hours: r.sla_hours.to_i }
    }.sort_by { |c| [c[:fee_minor], c[:eta_hours]] }
  end

  # A full quote: the cheapest courier + the road-graph (or zone-table) distance.
  def quote(address_tier:, weight_grams:, upazila_code:, cod_required: true)
    best = candidates(address_tier: address_tier, weight_grams: weight_grams, cod_required: cod_required).first
    dist = ShippingRouting.distance_km(upazila_code)
    return nil unless best
    best.merge(distance_km: dist[:distance_km], distance_source: dist[:source])
  end

  def valid_tier(tier)
    %w[city district upazila union].include?(tier.to_s) ? tier.to_s : DEFAULT_TIER
  end
end
