defmodule PaymentWeb.ErrorJSON do
  def render(_template, _assigns), do: %{error: %{code: "error", message: "internal error"}}
end
