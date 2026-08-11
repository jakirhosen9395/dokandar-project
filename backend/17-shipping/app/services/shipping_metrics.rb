require "prometheus/client"
require "prometheus/client/formats/text"

# Prometheus metrics — RED + shipping business + the MANDATORY shipping_outbox_pending
# gauge (§8.4). Closed-set labels only (courier/tier/status — never address/phone).
module ShippingMetrics
  REGISTRY = Prometheus::Client.registry
  SVC = "17-shipping".freeze

  def self.reg(type, name, doc, labels = [])
    REGISTRY.get(name) || REGISTRY.public_send(type, name, docstring: doc, labels: labels)
  end

  HTTP_REQUESTS = reg(:counter, :http_requests_total, "HTTP requests", %i[method route status])
  HTTP_DURATION = reg(:histogram, :http_request_duration_seconds, "HTTP latency", %i[method route])
  QUOTES   = reg(:counter, :shipping_quotes_total, "Delivery quotes served", %i[service courier])
  BOOKED   = reg(:counter, :shipping_booked_total, "Consignments booked", %i[service courier])
  FAILED   = reg(:counter, :shipping_failed_delivery_total, "Failed deliveries (COD refusal signal)", %i[service])
  OUTBOX   = reg(:gauge, :shipping_outbox_pending, "Outbox rows awaiting relay", %i[service])

  module_function

  def observe_http(method, route, status, seconds)
    HTTP_REQUESTS.increment(labels: { method: method, route: route, status: status.to_s })
    HTTP_DURATION.observe(seconds, labels: { method: method, route: route })
  rescue StandardError
    nil
  end

  def quote!(courier)  = QUOTES.increment(labels: { service: SVC, courier: courier.to_s })
  def booked!(courier) = BOOKED.increment(labels: { service: SVC, courier: courier.to_s })
  def failed_delivery! = FAILED.increment(labels: { service: SVC })
  def set_outbox_pending(n) = OUTBOX.set(n, labels: { service: SVC })

  def render
    Prometheus::Client::Formats::Text.marshal(REGISTRY)
  end
end
