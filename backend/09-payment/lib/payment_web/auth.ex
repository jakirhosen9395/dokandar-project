defmodule PaymentWeb.Auth do
  alias Payment.Config

  defp public_key do
    case Config.jwt_public_key_b64() do
      "" -> nil
      b64 -> (try do Base.decode64!(b64) rescue _ -> nil end)
    end
  end

  # → {:ok, claims} | {:error, status, code, message}
  def verify_user(conn) do
    case public_key() do
      nil -> {:error, 503, "server_misconfigured", "JWT_PUBLIC_KEY_B64 not configured"}
      pem ->
        auth = Plug.Conn.get_req_header(conn, "authorization") |> List.first()
        cond do
          is_nil(auth) or not String.starts_with?(String.downcase(auth), "bearer ") ->
            {:error, 401, "missing_token", "Bearer token required"}
          true ->
            token = String.trim(String.slice(auth, 7..-1//1))
            verify_token(token, pem)
        end
    end
  end

  defp verify_token(token, pem) do
    try do
      signer = Joken.Signer.create("RS256", %{"pem" => pem})
      case Joken.verify(token, signer) do
        {:ok, claims} ->
          now = System.system_time(:second)
          cond do
            claims["iss"] != Config.jwt_issuer() -> {:error, 401, "invalid_token", "invalid or expired token"}
            is_integer(claims["exp"]) and claims["exp"] < now -> {:error, 401, "invalid_token", "invalid or expired token"}
            is_nil(claims["sub"]) -> {:error, 401, "invalid_token", "invalid or expired token"}
            true -> {:ok, claims}
          end
        _ -> {:error, 401, "invalid_token", "invalid or expired token"}
      end
    rescue _ -> {:error, 401, "invalid_token", "invalid or expired token"}
    catch _, _ -> {:error, 401, "invalid_token", "invalid or expired token"}
    end
  end

  def verify_admin(conn) do
    case verify_user(conn) do
      {:ok, claims} ->
        if role(claims) in ~w(admin platform_staff), do: {:ok, claims}, else: {:error, 403, "insufficient_role", "admin or platform_staff required"}
      err -> err
    end
  end

  def role(claims), do: String.downcase(claims["role"] || "")
  def admin?(claims), do: role(claims) in ~w(admin platform_staff)

  def internal_ok?(conn) do
    expected = Config.internal_service_token()
    presented = Plug.Conn.get_req_header(conn, "x-internal-token") |> List.first()
    cond do
      expected == "" or is_nil(presented) -> false
      true -> Plug.Crypto.secure_compare(presented, expected)
    end
  end
end
