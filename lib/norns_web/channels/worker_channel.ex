defmodule NornsWeb.WorkerChannel do
  use NornsWeb, :channel

  alias Norns.Workers.WorkerRegistry

  @impl true
  def join("worker:lobby", %{"worker_id" => worker_id, "tools" => tools}, socket) do
    tenant_id = socket.assigns.tenant_id
    WorkerRegistry.register_worker(tenant_id, worker_id, self(), tools)
    socket = assign(socket, :worker_id, worker_id)
    {:ok, socket}
  end

  def join("worker:lobby", _params, _socket) do
    {:error, %{reason: "missing worker_id and tools"}}
  end

  @impl true
  def handle_in("tool_result", %{"task_id" => task_id} = payload, socket) do
    WorkerRegistry.deliver_result(task_id, payload)
    {:reply, :ok, socket}
  end

  @impl true
  def handle_info({:push_tool_task, task}, socket) do
    push(socket, "tool_task", task)
    {:noreply, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if worker_id = socket.assigns[:worker_id] do
      WorkerRegistry.unregister_worker(socket.assigns.tenant_id, worker_id)
    end

    :ok
  end
end
