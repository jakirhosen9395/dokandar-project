# Puma config — single worker, threaded. The gRPC server, the Kafka order.* consumer,
# and the outbox→Kafka relay run as plain Ruby THREADS spawned at boot (NOT Sidekiq —
# this service has no Redis, §3.3), so a single Puma process owns them all.
threads_count = ENV.fetch("RAILS_MAX_THREADS", 5).to_i
threads threads_count, threads_count

# REST listens on SERVICE_PORT (default 3000 → external 10017).
bind "tcp://0.0.0.0:#{ENV.fetch('SERVICE_PORT', ENV.fetch('PORT', 3000))}"

plugin :tmp_restart
pidfile ENV["PIDFILE"] if ENV["PIDFILE"]

# Start the background workers (gRPC server + outbox relay + order.* consumer) once the
# server has booted — NOT during db:prepare/db:seed rake (which never boots Puma).
on_booted do
  require_relative "../lib/shipping/workers"
  Shipping::Workers.start
end
