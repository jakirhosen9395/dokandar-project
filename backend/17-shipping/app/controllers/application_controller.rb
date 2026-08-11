class ApplicationController < ActionController::API
  # Scrub any unhandled 5xx — never leak a driver/stack to the client; log the raw cause.
  rescue_from StandardError do |e|
    Rails.logger.error("unhandled #{e.class}: #{e.message}")
    render_error("internal_error", "an internal error occurred", status: 500)
  end
  rescue_from ActiveRecord::RecordNotFound do
    render_error("not_found", "resource not found", status: 404)
  end

  # Pretty 2-space JSON (literal UTF-8 so Bangla is not escaped); trailing newline.
  def render_pretty(obj, status: 200)
    render body: JSON.pretty_generate(obj) + "\n",
           content_type: "application/json",
           status: status
  end

  # The one error envelope: { error: { code, message, request_id, details? } }.
  def render_error(code, message, status:, details: nil)
    err = { code: code, message: message, request_id: request.request_id }
    err[:details] = details unless details.nil?
    render_pretty({ error: err }, status: status)
  end

  # Bare-404 on unmapped paths: the BareNotFound middleware strips the body +
  # Content-Type when this marker header is set (mapped 404s keep the envelope).
  def bare_not_found
    response.headers["X-Bare-404"] = "1"
    head :not_found
  end

  # Verify the RS256 Bearer (auth's public key); returns the claims hash or nil.
  def current_claims
    return @current_claims if defined?(@current_claims)
    @current_claims = ShippingAuth.verify(request.headers["Authorization"])
  end

  def require_user!
    return if current_claims
    render_error("unauthorized", "a valid Bearer token is required", status: 401)
  end

  def require_admin!
    return if current_claims && current_claims["role"] == "admin"
    render_error("forbidden", "admin role required", status: 403)
  end
end
