defmodule PaymentWeb.CacheBodyReader do
  # Cache the raw request body so webhook HMAC can verify over the unparsed bytes.
  def read_body(conn, opts) do
    {:ok, body, conn} = Plug.Conn.read_body(conn, opts)
    conn = update_in(conn.assigns[:raw_body], fn acc -> [body | acc || []] end)
    {:ok, body, conn}
  end
end
