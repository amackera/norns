defmodule NornsWeb.AgentChannel do
  use NornsWeb, :channel

  alias Norns.Agents

  @impl true
  def join("agent:" <> agent_id_str, _params, socket) do
    agent_id = String.to_integer(agent_id_str)
    tenant_id = socket.assigns.tenant_id

    # Verify the agent belongs to this tenant
    agent = Agents.get_agent!(agent_id)

    if agent.tenant_id == tenant_id do
      {:ok, assign(socket, :agent_id, agent_id)}
    else
      {:error, %{reason: "not found"}}
    end
  rescue
    Ecto.NoResultsError -> {:error, %{reason: "not found"}}
  end

  @impl true
  def handle_in("send_message", %{"content" => content} = params, socket) do
    tenant_id = socket.assigns.tenant_id
    agent_id = socket.assigns.agent_id

    with {:ok, gard_id} <- validate_gard(tenant_id, Map.get(params, "gard_id")),
         {:ok, run_id} <-
           Norns.Agents.Registry.send_message(tenant_id, agent_id, content, gard_id: gard_id) do
      {:reply, {:ok, %{run_id: run_id}}, socket}
    else
      {:error, :gard_not_found} -> {:reply, {:error, %{reason: "gard not found"}}, socket}
      {:error, :busy} -> {:reply, {:error, %{reason: "agent is busy"}}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: inspect(reason)}}, socket}
    end
  end

  # A gard id from another tenant (or a typo) would create a run no worker can
  # ever serve — reject it up front rather than letting it queue to timeout.
  defp validate_gard(_tenant_id, nil), do: {:ok, nil}

  defp validate_gard(tenant_id, gard_id) do
    case Norns.Gards.get_gard(tenant_id, gard_id) do
      nil -> {:error, :gard_not_found}
      gard -> {:ok, gard.id}
    end
  end

  # Forward PubSub broadcasts from the agent process to the WebSocket client
  @impl true
  def handle_info({event, payload}, socket) when is_atom(event) do
    push(socket, Atom.to_string(event), payload)
    {:noreply, socket}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}
end
