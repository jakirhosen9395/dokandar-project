defmodule PaymentWeb.Endpoint do
  use Phoenix.Endpoint, otp_app: :payment

  plug Plug.RequestId, http_header: "x-request-id"
  plug PaymentWeb.Plugs.Observe
  plug Plug.Parsers,
    parsers: [{:json, length: 10_000_000}],
    pass: ["*/*"],
    json_decoder: Jason,
    body_reader: {PaymentWeb.CacheBodyReader, :read_body, []}
  plug PaymentWeb.Router
end
