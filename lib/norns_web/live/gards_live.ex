defmodule NornsWeb.GardsLive do
  use NornsWeb, :live_view

  alias Norns.Gards
  alias Norns.Workers.WorkerRegistry

  @impl true
  def mount(_params, session, socket) do
    case load_tenant(session) do
      {:ok, tenant} ->
        {:ok, assign(socket, tenant: tenant, current_tenant: tenant) |> load_gards()}

      :error ->
        {:ok, assign(socket, tenant: nil, current_tenant: nil, gards: [])}
    end
  end

  @impl true
  def handle_event("refresh", _params, socket) do
    {:noreply, load_gards(socket)}
  end

  defp load_gards(%{assigns: %{tenant: tenant}} = socket) do
    workers_by_gard =
      tenant.id
      |> WorkerRegistry.connected_workers()
      |> Enum.filter(& &1.gard)
      |> Map.new(fn w -> {w.gard, w} end)

    gards =
      tenant.id
      |> Gards.list_gards()
      |> Enum.map(fn gard ->
        %{
          gard: gard,
          ports: Gards.list_ports(gard.id),
          worker: workers_by_gard[gard.id]
        }
      end)

    assign(socket, gards: gards)
  end

  @impl true
  def render(assigns) do
    ~H"""
    <%= if @tenant == nil do %>
      <div class="mt-20 text-center text-gray-500">
        <p class="text-lg mb-2">Not authenticated</p>
        <p class="text-sm">Append <code class="text-gray-600 dark:text-gray-400">?token=your-api-key</code> to the URL</p>
      </div>
    <% else %>
      <div class="flex items-center justify-between mb-6">
        <h1 class="text-xl font-bold text-gray-900 dark:text-white">Gards</h1>
        <button phx-click="refresh" class="text-xs text-gray-500 hover:text-gray-700 dark:hover:text-gray-300">refresh</button>
      </div>

      <%= if @gards == [] do %>
        <p class="text-xs text-gray-500 dark:text-gray-600">
          No gards. Create one with <code class="text-gray-600 dark:text-gray-400">nornsctl gards create</code> —
          a gard pins all of a run's tool dispatch to one worker.
        </p>
      <% else %>
        <div class="space-y-2">
          <%= for %{gard: gard, ports: ports, worker: worker} <- @gards do %>
            <div class="bg-gray-50 dark:bg-gray-900 border border-gray-200 dark:border-gray-800 rounded px-4 py-3">
              <div class="flex items-center gap-3">
                <span class={status_class(gard.status)}>●</span>
                <span class="text-sm text-gray-900 dark:text-white"><%= gard.name || "gard_#{gard.id}" %></span>
                <span class="text-xs text-gray-500">#<%= gard.id %></span>
                <span class="text-xs text-gray-500"><%= gard.status %></span>
                <%= if gard.template do %>
                  <span class="text-xs text-gray-500">template: <%= gard.template %></span>
                <% end %>
                <%= if worker do %>
                  <span class="text-xs text-blue-700 dark:text-blue-600 ml-auto">
                    worker: <%= worker.worker_id %> (<%= worker.tool_count %> tools)
                  </span>
                <% end %>
              </div>

              <%= if ports != [] do %>
                <div class="mt-2 space-y-1">
                  <%= for port <- ports do %>
                    <div class="text-xs text-gray-600 dark:text-gray-400 pl-6">
                      :<%= port.internal_port %>
                      <%= if port.name && port.name != "" do %>(<%= port.name %>)<% end %>
                      <%= if port.url do %>
                        →
                        <a href={port.url} target="_blank" rel="noopener noreferrer" class="text-blue-700 dark:text-blue-500 hover:underline">
                          <%= port.url %>
                        </a>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              <% end %>
            </div>
          <% end %>
        </div>
      <% end %>
    <% end %>
    """
  end

  defp status_class("ready"), do: "text-green-600"
  defp status_class("pending"), do: "text-yellow-600"
  defp status_class("disconnected"), do: "text-red-600"
  defp status_class(_), do: "text-gray-500"

  defp load_tenant(%{"tenant_id" => tenant_id}) do
    {:ok, Norns.Tenants.get_tenant!(tenant_id)}
  rescue
    _ -> :error
  end

  defp load_tenant(_), do: :error
end
