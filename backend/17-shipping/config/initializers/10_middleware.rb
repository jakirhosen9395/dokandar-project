# Insert the bare-404 middleware innermost (it wraps the router so it sees the final 404).
require Rails.root.join("lib/shipping/bare_not_found").to_s
Rails.application.config.middleware.use Shipping::BareNotFound
