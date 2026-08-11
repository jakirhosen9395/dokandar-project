defmodule Payment.Bootstrap do
  # Create the DB if missing, then apply migrations/*.sql — before the Repo/Endpoint start.
  alias Payment.Config
  require Logger

  def ensure do
    db = Config.get("POSTGRES_DB", "dokandar_payment_dev")
    unless Regex.match?(~r/^[A-Za-z_][A-Za-z0-9_]*$/, db), do: raise("refusing unsafe db name: #{db}")
    base = [hostname: Config.get("POSTGRES_HOST"), port: Config.int("POSTGRES_PORT", 5432),
            username: Config.get("POSTGRES_USER", "postgres"), password: Config.get("POSTGRES_PASSWORD")]

    {:ok, admin} = Postgrex.start_link(base ++ [database: "postgres"])
    exists =
      case Postgrex.query(admin, "SELECT 1 FROM pg_database WHERE datname=$1", [db]) do
        {:ok, %{num_rows: 1}} -> true; _ -> false
      end
    unless exists do
      case Postgrex.query(admin, ~s(CREATE DATABASE "#{db}"), []) do
        {:ok, _} -> Logger.info("created database #{db}")
        {:error, %Postgrex.Error{postgres: %{code: :duplicate_database}}} -> :ok
        {:error, e} -> raise "create db failed: #{inspect(e)}"
      end
    end
    GenServer.stop(admin)

    {:ok, conn} = Postgrex.start_link(base ++ [database: db])
    dir = Enum.find(["migrations", "/app/migrations"], &File.dir?/1)
    File.ls!(dir) |> Enum.filter(&String.ends_with?(&1, ".sql")) |> Enum.sort()
    |> Enum.each(fn f ->
      File.read!(Path.join(dir, f))
      |> String.split(";")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "--")))
      |> Enum.each(fn stmt -> {:ok, _} = Postgrex.query(conn, stmt, []) end)
    end)
    GenServer.stop(conn)
    Logger.info("migrations applied; schema ready")
  end
end
