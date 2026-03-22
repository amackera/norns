defmodule Norns.Workers.TaskQueue do
  @moduledoc """
  Holds pending tool tasks when no worker is available.
  Tasks are flushed when a worker reconnects with matching tools.
  """

  use GenServer

  @stale_timeout_ms 300_000
  @sweep_interval_ms 30_000

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc "Add a task to the queue."
  def enqueue(tenant_id, task) do
    GenServer.cast(__MODULE__, {:enqueue, tenant_id, task})
  end

  @doc "Flush and return all queued tasks for a tool name."
  def flush(tenant_id, tool_name) do
    GenServer.call(__MODULE__, {:flush, tenant_id, tool_name})
  end

  @doc "Get queue depth for a tenant (for monitoring)."
  def depth(tenant_id) do
    GenServer.call(__MODULE__, {:depth, tenant_id})
  end

  # -- Callbacks --

  @impl true
  def init(_opts) do
    schedule_sweep()
    {:ok, %{queues: %{}}}
  end

  @impl true
  def handle_cast({:enqueue, tenant_id, task}, state) do
    task = Map.put_new(task, :queued_at, System.monotonic_time(:millisecond))
    queue = Map.get(state.queues, tenant_id, [])
    state = put_in(state.queues[tenant_id], queue ++ [task])
    {:noreply, state}
  end

  @impl true
  def handle_call({:flush, tenant_id, tool_name}, _from, state) do
    queue = Map.get(state.queues, tenant_id, [])
    {matching, remaining} = Enum.split_with(queue, &(&1.tool_name == tool_name))
    state = put_in(state.queues[tenant_id], remaining)
    {:reply, matching, state}
  end

  def handle_call({:depth, tenant_id}, _from, state) do
    count = state.queues |> Map.get(tenant_id, []) |> length()
    {:reply, count, state}
  end

  @impl true
  def handle_info(:sweep_stale, state) do
    now = System.monotonic_time(:millisecond)

    queues =
      Map.new(state.queues, fn {tenant_id, tasks} ->
        {stale, fresh} =
          Enum.split_with(tasks, fn task ->
            now - task.queued_at > @stale_timeout_ms
          end)

        # Notify waiting processes that their tasks timed out
        Enum.each(stale, fn task ->
          if pid = task[:from_pid], do: send(pid, {:tool_result, task.task_id, {:error, :timeout}})
        end)

        {tenant_id, fresh}
      end)

    schedule_sweep()
    {:noreply, %{state | queues: queues}}
  end

  defp schedule_sweep do
    Process.send_after(self(), :sweep_stale, @sweep_interval_ms)
  end
end
