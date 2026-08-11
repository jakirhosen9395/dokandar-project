class Courier < ApplicationRecord
  has_many :courier_pricing_rules, dependent: :destroy
  has_many :shipments
end
