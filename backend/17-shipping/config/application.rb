require_relative "boot"

require "rails"
# API-only: load just the railties we use (no solid_cache/queue/cable, no action_mailer/text).
require "active_model/railtie"
require "active_record/railtie"
require "action_controller/railtie"

Bundler.require(*Rails.groups)

module Shipping
  class Application < Rails::Application
    config.load_defaults 8.1
    config.api_only = true

    # lib/ holds non-Zeitwerk plumbing (the gRPC server, the runtime-generated proto
    # stubs, the Kafka relay/consumers, the 3-sink logger). It is required explicitly
    # from initializers — keep Zeitwerk out of it so generated/odd-named files don't
    # trip autoload naming.
    config.autoload_lib(ignore: %w[assets tasks shipping])

    # No Redis in this service (§3.3) → in-process memory cache. We use plain Ruby threads
    # for the gRPC server / Kafka consumer / outbox relay (NOT Sidekiq — it needs Redis),
    # so Active Job is not loaded at all.
    config.cache_store = :memory_store
  end
end
