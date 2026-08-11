require "jwt"
require "openssl"
require "rack/utils"

# Verify-only RS256 (auth's PUBLIC key) + the east-west INTERNAL_SERVICE_TOKEN.
# algorithms PINNED to ['RS256'] (alg:none / HS256-forgery rejected); issuer checked.
# The internal token is compared constant-time (Rack::Utils.secure_compare, §16-g).
module ShippingAuth
  module_function

  def verify(auth_header)
    return nil if auth_header.nil? || auth_header.to_s.empty?
    token = auth_header.to_s.sub(/\ABearer\s+/i, "").strip
    return nil if token.empty?
    pem = ShippingSettings.jwt_public_pem
    return nil if pem.nil?
    key = OpenSSL::PKey::RSA.new(pem)
    claims, = JWT.decode(token, key, true,
                         algorithms: ["RS256"],
                         iss: ShippingSettings.jwt_issuer, verify_iss: true)
    claims
  rescue StandardError
    nil
  end

  # Constant-time check of an x-internal-token value. Fail-closed on empty.
  def internal_ok?(token)
    expected = ShippingSettings.internal_token
    return false if expected.to_s.empty? || token.to_s.empty?
    Rack::Utils.secure_compare(token.to_s, expected.to_s)
  end
end
