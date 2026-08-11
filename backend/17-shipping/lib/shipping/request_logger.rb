module Shipping
  # One structured access line per genuine request (trace-correlated) + the RED metric.
  # Excludes /ready, /metrics, /health (§11, §16-k). Templated route only (UUID/number →
  # placeholder) so metric labels stay closed-set. NO recipient PII is ever logged.
  class RequestLogger
    SILENT = %w[/ready /metrics /health].freeze

    def initialize(app)
      @app = app
    end

    def call(env)
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      status, headers, body = @app.call(env)
      path = env["PATH_INFO"]
      unless SILENT.include?(path)
        secs = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
        method = env["REQUEST_METHOD"]
        route = templated(path)
        ShippingMetrics.observe_http(method, route, status, secs)
        Shipping::Logger.info("access #{method} #{route} #{status} #{(secs * 1000).round(1)}ms",
                              method: method, route: route, status: status,
                              request_id: env["action_dispatch.request_id"])
      end
      [status, headers, body]
    rescue StandardError
      @app.call(env)
    end

    def templated(path)
      path.gsub(%r{/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}}i, "/:id")
          .gsub(%r{/\d+}, "/:n")
    end
  end
end
