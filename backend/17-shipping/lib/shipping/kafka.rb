require "rdkafka"

# rdkafka producer (outbox relay) + consumer factory (order.* ingest). ruby-kafka is dead;
# rdkafka wraps librdkafka. acks=all on the producer (the outbox is the durable source).
module Shipping
  module Kafka
    module_function

    def producer
      @producer ||= Rdkafka::Config.new(
        "bootstrap.servers" => ENV.fetch("KAFKA_BOOTSTRAP", ""),
        "acks" => "all",
      ).producer
    end

    def produce(topic:, key:, payload:)
      # rdkafka is not auto-instrumented — emit a messaging span with a friendly "kafka" destination
      # so Kafka shows in Dependencies + the service map (runs under the OutboxRelay transaction).
      return producer.produce(topic: topic, key: key.to_s, payload: payload).wait unless apm_on?
      ElasticAPM.with_span("Kafka SEND to #{topic}", "messaging", subtype: "kafka", action: "send") do
        begin
          ElasticAPM.set_destination(
            service: ElasticAPM::Span::Context::Destination::Service.new(name: "kafka", resource: "kafka", type: "messaging")
          )
        rescue StandardError
          nil
        end
        producer.produce(topic: topic, key: key.to_s, payload: payload).wait
      end
    end

    def apm_on?
      defined?(ElasticAPM) && ElasticAPM.respond_to?(:running?) && ElasticAPM.running?
    end

    def consumer(group)
      Rdkafka::Config.new(
        "bootstrap.servers" => ENV.fetch("KAFKA_BOOTSTRAP", ""),
        "group.id" => group,
        "enable.auto.commit" => false,        # COMMIT-AFTER-HANDLE (§10)
        # earliest: a fulfilment consumer must NOT drop an order.confirmed (e.g. one produced
        # during the consumer's join window). Safe to re-read — booking is idempotent on the
        # shipments.idempotency_key (order_confirmed:<sub_order_id>) UNIQUE.
        "auto.offset.reset" => "earliest",
        "allow.auto.create.topics" => true,   # order.confirmed/cancelled may not exist until 13-order emits
      ).consumer
    end
  end
end
