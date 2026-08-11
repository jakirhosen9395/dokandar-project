require "json"

# Consume dokandar.order.confirmed (→ book a consignment) and dokandar.order.cancelled
# (→ cancel/recall), COMMIT-AFTER-HANDLE (§10). Idempotent: the shipments.idempotency_key
# UNIQUE (order_confirmed:<sub_order_id>) prevents a redelivered order.confirmed from
# double-booking. Reads the 13-order sub_orders/items shape (one sub-order per shop).
module Shipping
  module OrderConsumer
    TOPIC_CONFIRMED = ENV.fetch("KAFKA_TOPIC_ORDER_CONFIRMED", "dokandar.order.confirmed").freeze
    TOPIC_CANCELLED = ENV.fetch("KAFKA_TOPIC_ORDER_CANCELLED", "dokandar.order.cancelled").freeze

    module_function

    def run
      consumer = Shipping::Kafka.consumer(ENV.fetch("KAFKA_GROUP", "shipping"))
      consumer.subscribe(TOPIC_CONFIRMED, TOPIC_CANCELLED)
      Shipping::Logger.info("order consumer subscribed (#{TOPIC_CONFIRMED}, #{TOPIC_CANCELLED})")
      loop do
        msg = consumer.poll(1000)
        next unless msg
        ActiveRecord::Base.connection_pool.with_connection { handle(msg) }
        consumer.commit # commit-after-handle
      rescue StandardError => e
        Shipping::Logger.warn("order consumer error: #{e.class}: #{e.message}")
        sleep 2
      end
    end

    def handle(msg)
      ev = JSON.parse(msg.payload)
      return unless ev.is_a?(Hash)
      case msg.topic
      when TOPIC_CONFIRMED then on_confirmed(ev)
      when TOPIC_CANCELLED then on_cancelled(ev)
      end
    rescue JSON::ParserError
      nil
    end

    def sub_id_of(so) = so["sub_order_id"] || so["id"]

    def on_confirmed(ev)
      (ev["sub_orders"] || []).each do |so|
        sub = sub_id_of(so)
        next unless sub
        ShippingBooking.book(
          sub_order_id: sub,
          address_tier: so["address_tier"] || "district",
          upazila_code: so["upazila_code"],
          cod_amount_minor: so["cod_amount_minor"],
          idempotency_key: "order_confirmed:#{sub}",
        )
      end
    end

    def on_cancelled(ev)
      (ev["sub_orders"] || []).each do |so|
        sub = sub_id_of(so)
        next unless sub
        sh = Shipment.where(sub_order_id: sub).order(created_at: :desc).first
        next unless sh && !%w[delivered cancelled].include?(sh.status)
        ActiveRecord::Base.transaction do
          from = sh.status
          sh.update!(status: "cancelled")
          ShipmentEvent.create!(shipment: sh, from_status: from, to_status: "cancelled")
          Outbox.enqueue!(topic: ENV.fetch("KAFKA_TOPIC_SHIPMENT", "dokandar.shipment.status_changed"),
                          key: sub, payload: { event: "shipment.cancelled", shipment_id: sh.id,
                                               sub_order_id: sub, status: "cancelled" })
        end
      end
    end
  end
end
