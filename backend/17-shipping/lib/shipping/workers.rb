# Spawn the background workers as plain Ruby THREADS (no Sidekiq — this service has no
# Redis, §3.3): the gRPC server, the outbox→Kafka relay, and the order.* consumer. Called
# once from Puma's on_booted hook (so they start only when serving, not during db:prepare).
module Shipping
  module Workers
    @started = false

    module_function

    def start
      return if @started
      @started = true
      require Rails.root.join("lib/shipping/kafka").to_s
      require Rails.root.join("lib/shipping/outbox_relay").to_s
      require Rails.root.join("lib/shipping/order_consumer").to_s
      require Rails.root.join("lib/shipping/grpc_server").to_s

      Thread.new { Shipping::GrpcServer.start }

      unless ENV.fetch("KAFKA_BOOTSTRAP", "").empty?
        Thread.new { Shipping::OutboxRelay.run }
        Thread.new { Shipping::OrderConsumer.run }
      end
      Shipping::Logger.info("workers started (grpc + outbox relay + order consumer)")
    rescue StandardError => e
      warn "workers start failed: #{e.class}: #{e.message}"
    end
  end
end
