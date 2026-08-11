defmodule PaymentWeb.Helpers do
  import Plug.Conn
  def json_resp(conn, status, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(status, Jason.encode!(body, pretty: true) <> "\n")
  def error_resp(conn, status, code, message) do
    rid = (get_req_header(conn, "x-request-id") |> List.first()) || (get_resp_header(conn, "x-request-id") |> List.first())
    json_resp(conn, status, %{error: %{code: code, message: message, request_id: rid}})
  end
  def identity do
    boot = (try do :persistent_term.get(:payment_boot) rescue _ -> System.monotonic_time(:second) end)
    %{service_name: Payment.Config.service_name(), code_version: Payment.Config.code_version(),
      env_version: Payment.Config.env_version(), tenant: Payment.Config.tenant(),
      env: Payment.Config.app_env(), uptime_seconds: System.monotonic_time(:second) - boot}
  end
end
