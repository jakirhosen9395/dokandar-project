module Shipping
  # Bare-404 on unmapped paths: the catch-all controller action marks the response with
  # `X-Bare-404`; this middleware (innermost, wrapping the router) strips the body +
  # Content-Type and forces Content-Length:0. Mapped 404s (no marker) keep their envelope.
  class BareNotFound
    def initialize(app)
      @app = app
    end

    def call(env)
      status, headers, body = @app.call(env)
      marked = headers.delete("x-bare-404") || headers.delete("X-Bare-404")
      if status == 404 && marked
        body.close if body.respond_to?(:close)
        return [404, { "content-length" => "0" }, []]
      end
      [status, headers, body]
    end
  end
end
