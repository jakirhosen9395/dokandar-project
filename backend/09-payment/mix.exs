defmodule Payment.MixProject do
  use Mix.Project
  def project do
    [app: :payment, version: "0.1.0", elixir: "~> 1.18",
     elixirc_paths: ["lib"], start_permanent: Mix.env() == :prod, deps: deps()]
  end
  def application do
    [mod: {Payment.Application, []}, extra_applications: [:logger, :crypto, :inets, :ssl]]
  end
  defp deps do
    [
      {:phoenix, "~> 1.8.0"},
      {:bandit, "~> 1.5"},
      {:ecto_sql, "~> 3.12"},
      {:postgrex, "~> 0.19"},
      {:jason, "~> 1.4"},
      {:redix, "~> 1.5"},
      {:amqp, "~> 4.0"},
      {:brod, "~> 4.3"},
      {:joken, "~> 2.6"},
      {:req, "~> 0.5"},
      {:mongodb_driver, "~> 1.5"},
      {:telemetry, "~> 1.3"},
      {:opentelemetry, "~> 1.5"},
      {:opentelemetry_api, "~> 1.4"},
      {:opentelemetry_exporter, "~> 1.8"},
      {:opentelemetry_phoenix, "~> 2.0"},
      {:opentelemetry_bandit, "~> 0.2"},
      {:opentelemetry_ecto, "~> 1.2"}
    ]
  end
end
