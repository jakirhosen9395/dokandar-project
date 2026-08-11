require "json"

# Transactional-outbox relay (§10): poll `WHERE sent_at IS NULL FOR UPDATE SKIP LOCKED`,
# produce to Kafka, mark sent — modeled on 13-order / 09-payment. Producing inside the
# locked transaction means a Kafka failure rolls back (sent_at stays NULL → retried), and
# SKIP LOCKED makes it safe across pods. shipping_outbox_pending tracks relay lag.
module Shipping
  module OutboxRelay
    module_function

    def run
      loop do
        relayed = 0
        ActiveRecord::Base.connection_pool.with_connection do
          relayed = relay_batch
          refresh_gauge
        end
        sleep(relayed.zero? ? 1.0 : 0.05)
      rescue StandardError => e
        Shipping::Logger.warn("outbox relay error: #{e.class}: #{e.message}")
        sleep 2
      end
    end

    def relay_batch
      count = 0
      ActiveRecord::Base.transaction do
        rows = Outbox.where(sent_at: nil).order(:created_at).limit(100)
                     .lock("FOR UPDATE SKIP LOCKED").to_a
        # Wrap the batch in an APM transaction (this BACKGROUND JOB has no HTTP request) so the
        # Kafka producer spans + the row updates are captured and visible in APM.
        with_relay_txn(rows.size) do
          rows.each do |row|
            Shipping::Kafka.produce(topic: row.topic, key: row.key, payload: JSON.generate(row.payload))
            row.update_column(:sent_at, Time.now)
            count += 1
          end
        end
      end
      count
    end

    def with_relay_txn(n)
      return yield if n.zero? || !(defined?(ElasticAPM) && ElasticAPM.respond_to?(:running?) && ElasticAPM.running?)
      ElasticAPM.with_transaction("OutboxRelay relay", "messaging") { yield }
    end

    def refresh_gauge
      ShippingMetrics.set_outbox_pending(Outbox.where(sent_at: nil).count)
    rescue StandardError
      nil
    end
  end
end
