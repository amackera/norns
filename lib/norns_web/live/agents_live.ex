defmodule NornsWeb.AgentsLive do
  use NornsWeb, :live_view

  alias Norns.Agents
  alias Norns.Agents.Registry

  @impl true
  def mount(_params, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        agents = Agents.list_agents(tenant.id)

        if connected?(socket) do
          Enum.each(agents, fn a ->
            Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{a.id}")
          end)
        end

        {:ok, assign(socket, tenant: tenant, current_tenant: tenant, agents: agents, agent_states: build_states(agents, tenant))}

      :error ->
        {:ok, assign(socket, tenant: nil, current_tenant: nil, agents: [], agent_states: %{})}
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @tenant == nil do %>
      <div class="mt-20 text-center text-gray-500">
        <p class="text-lg mb-2">Not authenticated</p>
        <p class="text-sm">Append <code class="text-gray-400">?token=your-api-key</code> to the URL</p>
      </div>
    <% else %>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-xl font-bold text-white">Agents</h1>
        <span class="text-xs text-gray-600"><%= length(@agents) %> agents</span>
      </div>

      <%= if @agents == [] do %>
        <p class="text-gray-500 text-sm">No agents yet. Create one via the API.</p>
      <% else %>
        <div class="space-y-2">
          <%= for agent <- @agents do %>
            <% state = Map.get(@agent_states, agent.id) %>
            <div class="flex items-center justify-between bg-gray-900 border border-gray-800 rounded px-4 py-3">
              <div class="flex items-center gap-3">
                <span class={["w-2 h-2 rounded-full", status_color(state)]}>
                </span>
                <a href={"/agents/#{agent.id}"} class="text-white hover:text-blue-400">
                  <%= agent.name %>
                </a>
                <span class="text-xs text-gray-600"><%= agent.model %></span>
              </div>
              <div class="flex items-center gap-3">
                <span class="text-xs text-gray-500">
                  <%= if state && state.status == :running, do: "step #{state.step}", else: agent.status %>
                </span>
                <%= if state && state.status != :stopped do %>
                  <button phx-click="stop" phx-value-id={agent.id}
                    class="text-xs text-red-400 hover:text-red-300 border border-red-900 px-2 py-1 rounded">
                    stop
                  </button>
                <% else %>
                  <button phx-click="start" phx-value-id={agent.id}
                    class="text-xs text-green-400 hover:text-green-300 border border-green-900 px-2 py-1 rounded">
                    start
                  </button>
                <% end %>
              </div>
            </div>
          <% end %>
        </div>
      <% end %>
    <% end %>
    """
  end

  @impl true
  def handle_event("start", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    tenant = socket.assigns.tenant
    Registry.start_agent(agent_id, tenant.id)
    Phoenix.PubSub.subscribe(Norns.PubSub, "agent:#{agent_id}")
    {:noreply, refresh(socket)}
  end

  def handle_event("stop", %{"id" => id}, socket) do
    agent_id = String.to_integer(id)
    Registry.stop_agent(socket.assigns.tenant.id, agent_id)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_info({event, _payload}, socket)
      when event in [:agent_started, :completed, :error, :agent_resumed] do
    {:noreply, refresh(socket)}
  end

  def handle_info(_msg, socket), do: {:noreply, socket}

  defp refresh(socket) do
    agents = Agents.list_agents(socket.assigns.tenant.id)
    assign(socket, agents: agents, agent_states: build_states(agents, socket.assigns.tenant))
  end

  defp build_states(agents, tenant) do
    Map.new(agents, fn agent ->
      state =
        case Registry.lookup(tenant.id, agent.id) do
          {:ok, pid} -> Agents.Process.get_state(pid)
          :error -> %{status: :stopped, step: 0}
        end

      {agent.id, state}
    end)
  end

  defp status_color(%{status: :running}), do: "bg-green-400 animate-pulse-dot"
  defp status_color(%{status: :idle}), do: "bg-blue-400"
  defp status_color(_), do: "bg-gray-600"

  defp load_tenant(%{"tenant_id" => tenant_id}) do
    {:ok, Norns.Tenants.get_tenant!(tenant_id)}
  rescue
    _ -> :error
  end

  defp load_tenant(_), do: :error
end
