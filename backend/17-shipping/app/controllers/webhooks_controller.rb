require "rack/utils"

# Courier status callbacks. Authenticated by COURIER SIGNATURE (not JWT), verified
# constant-time (§12). A failed_delivery emits dokandar.shipment.failed_delivery — the
# COD-refusal label 18-risk-trust trains on. Idempotent (a repeat is a 200 no-op).
class WebhooksController < ApplicationController
  # POST /api/v1/shipping/webhooks/:courier
  def receive
    courier = params[:courier].to_s
    return render_error("signature_invalid", "courier signature missing or invalid", status: 403) unless signature_ok?(courier)

    shipment = find_shipment(params[:sub_order_id], params[:tracking_code])
    return render_pretty({ ok: true, note: "no matching shipment" }, status: 200) unless shipment  # idempotent ack

    apply_status(shipment, params[:status].to_s, courier)
    render_pretty({ ok: true, shipment_id: shipment.id, status: shipment.reload.status })
  end

  private

  def signature_ok?(courier)
    secret = ENV["#{courier.upcase}_WEBHOOK_SECRET"].presence ||
             ENV.fetch("SHIPPING_WEBHOOK_SECRET", "dokandar_shipping_webhook_dev")
    sig = request.headers["X-Courier-Signature"].to_s
    !sig.empty? && Rack::Utils.secure_compare(sig, secret)
  end

  def find_shipment(sub_order_id, tracking_code)
    return Shipment.find_by(tracking_code: tracking_code) if tracking_code.present?
    Shipment.where(sub_order_id: sub_order_id).order(created_at: :desc).first if sub_order_id.present?
  end

  def apply_status(shipment, new_status, courier)
    return unless Shipment::STATUSES.include?(new_status)
    from = shipment.status
    return if from == new_status # idempotent

    ActiveRecord::Base.transaction do
      shipment.update!(status: new_status,
                       delivered_at: new_status == "delivered" ? Time.now : shipment.delivered_at)
      ShipmentEvent.create!(shipment: shipment, from_status: from, to_status: new_status,
                            courier_raw: { courier: courier, status: new_status, tracking_code: params[:tracking_code] }) # NO recipient PII
      topic = case new_status
              when "delivered"       then ENV.fetch("KAFKA_TOPIC_SHIPMENT_DELIVERED", "dokandar.shipment.delivered")
              when "failed_delivery" then ENV.fetch("KAFKA_TOPIC_SHIPMENT_FAILED", "dokandar.shipment.failed_delivery")
              else ENV.fetch("KAFKA_TOPIC_SHIPMENT", "dokandar.shipment.status_changed")
              end
      Outbox.enqueue!(topic: topic, key: shipment.sub_order_id,
                      payload: { event: "shipment.#{new_status}", shipment_id: shipment.id,
                                 sub_order_id: shipment.sub_order_id, status: new_status, courier: courier })
    end
    ShippingMetrics.failed_delivery! if new_status == "failed_delivery"
  end
end
