defmodule Payment.Repo do
  use Ecto.Repo, otp_app: :payment, adapter: Ecto.Adapters.Postgres

  # Read connection config directly from the env at boot (robust vs runtime.exs loading).
  def init(_type, config) do
    {:ok, Keyword.merge(config, [
      hostname: System.get_env("POSTGRES_HOST"),
      port: String.to_integer(System.get_env("POSTGRES_PORT") || "5432"),
      username: System.get_env("POSTGRES_USER") || "postgres",
      password: System.get_env("POSTGRES_PASSWORD") || "",
      database: System.get_env("POSTGRES_DB") || "dokandar_payment_dev",
      pool_size: 10,
      queue_target: 5_000
    ])}
  end
end
