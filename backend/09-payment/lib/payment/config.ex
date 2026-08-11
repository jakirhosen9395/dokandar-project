defmodule Payment.Config do
  def get(k, d \\ ""), do: System.get_env(k) || d
  def int(k, d), do: (case System.get_env(k) do nil -> d; v -> String.to_integer(v) end)

  def app_env, do: get("APP_ENV", "dev")
  def service_name, do: get("SERVICE_NAME", "09-payment")
  def env_version, do: get("ENV_VERSION", "v1.0.0")
  def tenant, do: get("TENANT", "local")
  def service_port, do: int("SERVICE_PORT", 4000)
  def code_version do
    Enum.find_value(["CODE_VERSION", "/app/CODE_VERSION"], "0-unknown", fn p ->
      case File.read(p) do {:ok, v} -> String.trim(v); _ -> nil end
    end)
  end

  def redis_host, do: get("REDIS_HOST")
  def redis_port, do: int("REDIS_PORT", 6379)
  def redis_password, do: get("REDIS_PASSWORD")
  def redis_db, do: int("REDIS_DB", 8)
  def kafka_bootstrap, do: get("KAFKA_BOOTSTRAP")
  def rabbitmq_url, do: get("RABBITMQ_URL")
  def rabbitmq_payout_queue, do: get("RABBITMQ_PAYOUT_QUEUE", "payout.execute")
  def mongo_log_uri, do: get("MONGO_LOG_URI")
  def mongo_log_db, do: get("MONGO_LOG_DB", "mongo_db_dokandar_application_logs")
  def es_url, do: get("ELASTIC_SEARCH_URL")
  def es_user, do: get("ELASTIC_SEARCH_USERNAME")
  def es_password, do: get("ELASTIC_SEARCH_PASSWORD")
  def apm_server_url, do: get("APM_SERVER_URL")
  def apm_service_name, do: get("APM_SERVICE_NAME", "09-payment")
  def jwt_public_key_b64, do: get("JWT_PUBLIC_KEY_B64")
  def jwt_issuer, do: get("JWT_ISSUER", "dokandar-auth")
  def internal_service_token, do: get("INTERNAL_SERVICE_TOKEN")
  def webhook_secret, do: get("PAYMENT_STUB_WEBHOOK_SECRET", "stub_webhook_secret")
  def commission_default_bps, do: int("PAYMENT_COMMISSION_DEFAULT_BPS", 250)

  def topic_intent_created, do: "dokandar.payment.intent_created"
  def topic_settled, do: "dokandar.payment.settled"
  def topic_failed, do: "dokandar.payment.failed"
  def topic_payout_completed, do: "dokandar.payment.payout_completed"
  def topic_refund_processed, do: "dokandar.refund.processed"
end
