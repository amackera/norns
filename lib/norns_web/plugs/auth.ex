defmodule NornsWeb.Plugs.Auth do
  @moduledoc "Bearer token auth — matches token against tenant api_keys values."

  import Plug.Conn

  def init(opts), do: opts

  def call(conn, _opts) do
    with ["Bearer " <> token] <- get_req_header(conn, "authorization"),
         {:ok, tenant} <- Norns.Tenants.get_tenant_by_api_key(token) do
      assign(conn, :current_tenant, tenant)
    else
      _ ->
        conn
        |> put_status(401)
        |> Phoenix.Controller.json(%{error: "unauthorized"})
        |> halt()
    end
  end
end
