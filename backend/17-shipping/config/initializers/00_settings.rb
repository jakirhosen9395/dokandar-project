# Runtime config + the shared identity block. Reads ENV (injected via --env-file) and the
# repo-root CODE_VERSION once at boot. Fail-fast on an empty SERVICE_NAME (always) and on an
# empty JWT_PUBLIC_KEY_B64 / INTERNAL_SERVICE_TOKEN under stage/prod (§9, §14).
module ShippingSettings
  module_function

  BOOT_AT = Process.clock_gettime(Process::CLOCK_MONOTONIC)

  def env(key, default = nil) = ENV.fetch(key, default)
  def app_env       = env("APP_ENV", "dev")
  def service_name  = env("SERVICE_NAME", "17-shipping")
  def env_version   = env("ENV_VERSION", "v1.0.0")
  def tenant        = env("TENANT", "local")
  def grpc_enabled  = env("GRPC_ENABLED", "true") == "true"
  def grpc_port     = env("GRPC_PORT", "8001").to_i
  def internal_token = env("INTERNAL_SERVICE_TOKEN", "")

  def code_version
    @code_version ||= (Rails.root.join("CODE_VERSION").read.strip rescue "0-unknown")
  end

  def jwt_public_pem
    return @jwt_public_pem if defined?(@jwt_public_pem)
    b64 = env("JWT_PUBLIC_KEY_B64", "")
    # decode via String#unpack1("m") — avoids depending on the base64 bundled gem (Ruby 3.4).
    @jwt_public_pem = b64.empty? ? nil : (b64.unpack1("m") rescue nil)
  end
  def jwt_issuer = env("JWT_ISSUER", "dokandar-auth")

  def uptime_seconds
    (Process.clock_gettime(Process::CLOCK_MONOTONIC) - BOOT_AT).to_i
  end

  def identity
    {
      service_name: service_name,
      code_version: code_version,
      env_version: env_version,
      tenant: tenant,
      env: app_env,
      uptime_seconds: uptime_seconds,
    }
  end
end

# Fail-fast guards.
raise "FATAL: SERVICE_NAME is empty" if ShippingSettings.service_name.to_s.empty?
if %w[stage prod].include?(ShippingSettings.app_env)
  raise "FATAL: JWT_PUBLIC_KEY_B64 empty under #{ShippingSettings.app_env}" unless ShippingSettings.jwt_public_pem
  raise "FATAL: INTERNAL_SERVICE_TOKEN empty under #{ShippingSettings.app_env}" if ShippingSettings.internal_token.empty?
end
