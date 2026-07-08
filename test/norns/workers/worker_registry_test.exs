defmodule Norns.Workers.WorkerRegistryTest do
  use ExUnit.Case, async: false

  alias Norns.Workers.WorkerRegistry

  setup do
    # WorkerRegistry is started by the application
    :ok
  end

  describe "register_worker/4 and available_tools/1" do
    test "registers a worker and exposes its tools" do
      tools = [%{"name" => "query_db", "description" => "Run SQL", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "worker-1", self(), tools)

      remote_tools = WorkerRegistry.available_tools(1)
      assert length(remote_tools) == 1
      assert hd(remote_tools).name == "query_db"
      assert hd(remote_tools).source == {:remote, 1}

      # Cleanup
      WorkerRegistry.unregister_worker(1, "worker-1")
    end

    test "tools are tenant-scoped" do
      tools = [%{"name" => "tool_a", "description" => "A", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "w1", self(), tools)

      assert [_] = WorkerRegistry.available_tools(1)
      assert [] = WorkerRegistry.available_tools(2)

      WorkerRegistry.unregister_worker(1, "w1")
    end
  end

  describe "unregister_worker/2" do
    test "removes worker tools" do
      tools = [%{"name" => "tool_b", "description" => "B", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "w2", self(), tools)

      WorkerRegistry.unregister_worker(1, "w2")
      # Give cast time to process
      Process.sleep(50)

      assert WorkerRegistry.available_tools(1) == []
    end
  end

  describe "dispatch_task/4 and deliver_result/2" do
    test "dispatches task to connected worker" do
      tools = [%{"name" => "search", "description" => "Search", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "w3", self(), tools)

      {:ok, task_id} = WorkerRegistry.dispatch_task(1, "search", %{"q" => "test"}, from_pid: self())
      assert is_binary(task_id)

      # Simulate worker delivering result
      WorkerRegistry.deliver_result(task_id, %{"status" => "ok", "result" => "found it"})

      assert {:ok, "found it"} = WorkerRegistry.await_result(task_id, 1000)

      WorkerRegistry.unregister_worker(1, "w3")
    end

    test "delivers error results" do
      tools = [%{"name" => "fail_tool", "description" => "Fail", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "w4", self(), tools)

      {:ok, task_id} = WorkerRegistry.dispatch_task(1, "fail_tool", %{}, from_pid: self())
      WorkerRegistry.deliver_result(task_id, %{"status" => "error", "error" => "boom"})

      assert {:error, "boom"} = WorkerRegistry.await_result(task_id, 1000)

      WorkerRegistry.unregister_worker(1, "w4")
    end

    test "rejects invalid result payloads deterministically" do
      tools = [%{"name" => "shape_check", "description" => "Shape", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "w5", self(), tools)

      {:ok, task_id} = WorkerRegistry.dispatch_task(1, "shape_check", %{}, from_pid: self())
      WorkerRegistry.deliver_result(task_id, %{"task_id" => task_id, "status" => "ok"})

      assert {:error, "invalid result payload"} = WorkerRegistry.await_result(task_id, 1_000)

      WorkerRegistry.unregister_worker(1, "w5")
    end

    test "queues tool tasks and flushes them on worker reconnect" do
      {:ok, task_id} = WorkerRegistry.dispatch_task(1, "queued_tool", %{"job" => "later"}, from_pid: self())

      assert is_binary(task_id)

      :ok =
        WorkerRegistry.register_worker(1, "queued-worker", self(), [
          %{"name" => "queued_tool", "description" => "Queued", "input_schema" => %{}}
        ])

      assert_receive {:push_tool_task, %{task_id: ^task_id, tool_name: "queued_tool", input: %{"job" => "later"}}}, 1_000

      WorkerRegistry.deliver_result(task_id, %{"status" => "ok", "result" => "flushed"})

      assert {:ok, "flushed"} = WorkerRegistry.await_result(task_id, 1_000)

      WorkerRegistry.unregister_worker(1, "queued-worker")
    end

    test "dispatches tenant-scoped tasks only to workers for that tenant" do
      tools = [%{"name" => "search", "description" => "Search", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "tenant-a", self(), tools)
      :ok = WorkerRegistry.register_worker(2, "tenant-b", spawn(fn -> Process.sleep(:infinity) end), tools)

      {:ok, task_id} = WorkerRegistry.dispatch_task(1, "search", %{"q" => "tenant-a"}, from_pid: self())

      assert_receive {:push_tool_task, %{task_id: ^task_id, tool_name: "search", input: %{"q" => "tenant-a"}}}, 1_000

      WorkerRegistry.unregister_worker(1, "tenant-a")
      WorkerRegistry.unregister_worker(2, "tenant-b")
    end
  end

  describe "worker crash recovery" do
    test "reclaims in-flight tasks when a worker reconnects under the same id" do
      tools = [%{"name" => "reconnect_tool", "description" => "R", "input_schema" => %{}}]
      :ok = WorkerRegistry.register_worker(1, "recon", self(), tools)

      {:ok, task_id} = WorkerRegistry.dispatch_task(1, "reconnect_tool", %{}, from_pid: self())
      assert_receive {:push_tool_task, %{task_id: ^task_id}}, 1_000

      # The worker crashes and its container reconnects: a fresh registration
      # arrives under the same {tenant, worker_id} key. The task that was in
      # flight to the dead incarnation is lost and must be reclaimed at once,
      # rather than stranding the run until the 5-minute task timeout.
      :ok = WorkerRegistry.register_worker(1, "recon", self(), tools)

      assert_receive {:task_result, ^task_id, {:error, "worker disconnected"}}, 1_000

      WorkerRegistry.unregister_worker(1, "recon")
    end

    test "reclaim is scoped to the disconnected worker, not the whole tenant" do
      pid_a = spawn(fn -> Process.sleep(:infinity) end)
      pid_b = spawn(fn -> Process.sleep(:infinity) end)
      :ok = WorkerRegistry.register_worker(1, "wa", pid_a, [%{"name" => "tool_a", "description" => "A", "input_schema" => %{}}])
      :ok = WorkerRegistry.register_worker(1, "wb", pid_b, [%{"name" => "tool_b", "description" => "B", "input_schema" => %{}}])

      {:ok, task_id} = WorkerRegistry.dispatch_task(1, "tool_a", %{}, from_pid: self())

      # Disconnecting a different worker on the same tenant must not fail this task.
      WorkerRegistry.unregister_worker(1, "wb")
      refute_receive {:task_result, ^task_id, _}, 300

      # Disconnecting the owning worker reclaims it.
      WorkerRegistry.unregister_worker(1, "wa")
      assert_receive {:task_result, ^task_id, {:error, "worker disconnected"}}, 1_000
    end

    test "a late terminate from a replaced connection does not evict the new worker" do
      old_pid = spawn(fn -> Process.sleep(:infinity) end)
      tools = [%{"name" => "guard_tool", "description" => "G", "input_schema" => %{}}]

      :ok = WorkerRegistry.register_worker(1, "guarded", old_pid, tools)
      # Reconnect: same worker_id, new channel pid.
      :ok = WorkerRegistry.register_worker(1, "guarded", self(), tools)

      # The old connection's terminate arrives late, carrying the old pid.
      WorkerRegistry.unregister_worker(1, "guarded", old_pid)
      Process.sleep(50)

      # The reconnected worker is still registered.
      assert [%{name: "guard_tool"}] = WorkerRegistry.available_tools(1)

      WorkerRegistry.unregister_worker(1, "guarded", self())
    end
  end
end
