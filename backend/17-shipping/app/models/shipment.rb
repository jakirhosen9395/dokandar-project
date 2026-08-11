class Shipment < ApplicationRecord
  has_many :shipment_events, dependent: :destroy
  belongs_to :courier, optional: true

  STATUSES = %w[pending booked in_transit delivered failed_delivery returned cancelled].freeze

  def to_dto
    {
      id: id, sub_order_id: sub_order_id, status: status,
      courier: courier&.name, address_tier: address_tier, upazila_code: upazila_code,
      cod_amount_minor: cod_amount_minor, tracking_code: tracking_code,
      booked_at: booked_at, delivered_at: delivered_at, created_at: created_at
    }
  end
end
