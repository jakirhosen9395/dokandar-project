# Start the 3-sink logger (background drain thread) + insert the access-log/RED middleware
# innermost (it wraps the router but runs inside the APM transaction → trace-correlated).
require Rails.root.join("lib/shipping/logger").to_s
require Rails.root.join("lib/shipping/request_logger").to_s

Shipping::Logger.start
Rails.application.config.middleware.use Shipping::RequestLogger
