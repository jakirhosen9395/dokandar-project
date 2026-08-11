require "active_support/core_ext/integer/time"

Rails.application.configure do
  config.enable_reloading = false
  config.eager_load = true
  config.consider_all_requests_local = false

  # No asset pipeline (API-only); in-process memory cache (no Redis, §3.3).
  config.cache_store = :memory_store

  # Log to STDOUT (the container captures it; the 3-sink logger ships structured copies).
  config.log_tags = [:request_id]
  config.logger = ActiveSupport::TaggedLogging.logger($stdout)
  config.log_level = ENV.fetch("LOG_LEVEL", "info")
  config.active_support.report_deprecations = false

  # TLS is terminated upstream (the LB / 15-api-gateway).
  config.force_ssl = false

  # secret_key_base is required in production; injected at runtime. The service is
  # API-only and verifies RS256 JWTs — it mints no cookies/sessions.
  config.secret_key_base = ENV.fetch("SECRET_KEY_BASE", "dokandar-17-shipping-dev-secret-key-base-not-for-real-prod")

  config.active_record.dump_schema_after_migration = false
  config.i18n.fallbacks = true

  # Allow all hosts — the gateway is the trust boundary; this service sits behind it.
  config.hosts.clear
end
