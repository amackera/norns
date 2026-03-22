defmodule NornsWeb.AgentSocket do
  use Phoenix.Socket

  channel "agent:*", NornsWeb.AgentChannel

  @impl true
  def connect(%{"token" => token}, socket, _connect_info) do
    case Norns.Tenants.get_tenant_by_api_key(token) do
      {:ok, tenant} ->
        {:ok, assign(socket, :tenant_id, tenant.id)}

      _ ->
        :error
    end
  end

  def connect(_params, _socket, _connect_info), do: :error

  @impl true
  def id(socket), do: "agent_socket:#{socket.assigns.tenant_id}"
end
