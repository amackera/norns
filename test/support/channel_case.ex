defmodule NornsWeb.ChannelCase do
  @moduledoc "Test case template for channel tests."

  use ExUnit.CaseTemplate

  using do
    quote do
      import Phoenix.ChannelTest
      import Norns.DataCase, only: [create_tenant: 0, create_tenant: 1, create_agent: 1, create_agent: 2]

      @endpoint NornsWeb.Endpoint
    end
  end

  setup tags do
    pid = Ecto.Adapters.SQL.Sandbox.start_owner!(Norns.Repo, shared: not tags[:async])
    on_exit(fn -> Ecto.Adapters.SQL.Sandbox.stop_owner(pid) end)

    unless tags[:async] do
      Ecto.Adapters.SQL.Sandbox.mode(Norns.Repo, {:shared, self()})
    end

    :ok
  end
end
