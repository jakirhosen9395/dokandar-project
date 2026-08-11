class Outbox < ApplicationRecord
  self.table_name = "outbox"

  # Enqueue a domain event in the SAME DB transaction as the state change (transactional
  # outbox, §10). The relay polls `WHERE sent_at IS NULL FOR UPDATE SKIP LOCKED`.
  def self.enqueue!(topic:, key:, payload:)
    create!(topic: topic, key: key, payload: payload)
  end
end
