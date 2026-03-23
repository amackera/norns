defmodule NornsWeb.Plugs.SessionAuth do
  @moduledoc """
  Session-based auth for the browser UI. On first visit, pass ?token=<api_key>
  to authenticate. The tenant is stored in the session for subsequent requests.
  """

  import Plug.Conn
  import Phoenix.Controller

  def init(opts), do: opts

  def call(conn, _opts) do
    cond do
      # Token in query params — authenticate and store in session
      token = conn.params["token"] ->
        case Norns.Tenants.get_tenant_by_api_key(token) do
          {:ok, tenant} ->
            conn
            |> put_session(:tenant_id, tenant.id)
            |> assign(:current_tenant, tenant)
            |> redirect(to: conn.request_path)
            |> halt()

          _ ->
            conn |> assign(:current_tenant, nil)
        end

      # Tenant ID in session — load it
      tenant_id = get_session(conn, :tenant_id) ->
        try do
          tenant = Norns.Tenants.get_tenant!(tenant_id)
          assign(conn, :current_tenant, tenant)
        rescue
          _ -> assign(conn, :current_tenant, nil)
        end

      # No auth
      true ->
        assign(conn, :current_tenant, nil)
    end
  end
end
