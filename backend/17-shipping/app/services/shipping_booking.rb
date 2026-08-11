require "securerandom"

# Consignment booking (§4.1). Idempotent on the shipments.idempotency_key UNIQUE so a
# redelivered order.confirmed or a retried POST never double-books. Picks a courier and
# fails over to the next-best (the courier API call is stubbed — no real outbound). Writes
# the shipment + a shipment_event + the outbox row in ONE transaction (transactional outbox).
module ShippingBooking
  module_function

  Result = Struct.new(:shipment, :created, keyword_init: true)

  def book(sub_order_id:, address_tier:, upazila_code:, cod_amount_minor:, idempotency_key:)
    existing = Shipment.find_by(idempotency_key: idempotency_key)
    return Result.new(shipment: existing, created: false) if existing

    cod_required = !cod_amount_minor.nil? && cod_amount_minor.to_i > 0
    cands = CourierSelector.candidates(address_tier: address_tier, weight_grams: 1000, cod_required: cod_required)
    chosen = book_with_failover(cands)

    shipment = nil
    ActiveRecord::Base.transaction do
      shipment = Shipment.create!(
        sub_order_id: sub_order_id,
        address_tier: CourierSelector.valid_tier(address_tier),
        upazila_code: upazila_code,
        cod_amount_minor: cod_amount_minor,
        idempotency_key: idempotency_key,
        courier_id: chosen&.dig(:courier_id),
        status: chosen ? "booked" : "pending",
        tracking_code: chosen ? "TRK-#{SecureRandom.hex(6).upcase}" : nil,
        booked_at: chosen ? Time.now : nil,
      )
      ShipmentEvent.create!(shipment: shipment, from_status: nil, to_status: shipment.status)
      Outbox.enqueue!(
        topic: ENV.fetch("KAFKA_TOPIC_SHIPMENT", "dokandar.shipment.status_changed"),
        key: sub_order_id,
        payload: { event: "shipment.booked", shipment_id: shipment.id, sub_order_id: sub_order_id,
                   courier: chosen&.dig(:courier), status: shipment.status },
      )
    end
    ShippingMetrics.booked!(chosen[:courier]) if chosen
    Result.new(shipment: shipment, created: true)
  rescue ActiveRecord::RecordNotUnique
    Result.new(shipment: Shipment.find_by(idempotency_key: idempotency_key), created: false)
  end

  # (stub) try each candidate until one "accepts". A real impl calls the courier API and
  # fails over to the next on rejection / outage (§13). Returns the chosen candidate or nil.
  def book_with_failover(candidates)
    candidates.first
  end
end
