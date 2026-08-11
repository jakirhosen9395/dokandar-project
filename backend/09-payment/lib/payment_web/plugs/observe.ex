defmodule PaymentWeb.Plugs.Observe do
  import Plug.Conn
  alias Payment.Obs.{Metrics, Log}
  def init(o), do: o
  def call(conn, _) do
    register_before_send(conn, fn conn ->
      path = conn.request_path
      route = normalize(path)
      Metrics.inc("http_requests_total", [method: conn.method, route: route, status: conn.status])
      unless path == "/ready" or path == "/metrics" do
        ip = (try do conn.remote_ip |> :inet.ntoa() |> to_string() rescue _ -> "-" end)
        Log.access("#{ip}:0", conn.method, conn.request_path, conn.status, "")
      end
      conn
    end)
  end
  defp normalize(path), do: String.replace(path, ~r/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}/, ":id")
end
