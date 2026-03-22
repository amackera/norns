defmodule NornsWeb.ConnCase do
  @moduledoc "Test case template for controller tests."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Plug.Conn
      import Phoenix.ConnTest
      import Norns.DataCase, only: [create_tenant: 0, create_tenant: 1, create_agent: 1, create_agent: 2]
      import NornsWeb.ConnCase

      @endpoint NornsWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Norns.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Norns.Repo, {:shared, self()})
    end

    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end

  @doc "Build an authenticated connection for a tenant."
  def authenticated_conn(conn, tenant) do
    # Use the first api key value from the tenant
    token = tenant.api_keys |> Map.values() |> List.first()

    conn
    |> Plug.Conn.put_req_header("authorization", "Bearer #{token}")
    |> Plug.Conn.put_req_header("content-type", "application/json")
  end
end
