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

      assert length(WorkerRegistry.available_tools(1)) == 1
      assert length(WorkerRegistry.available_tools(2)) == 0

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
  end
end
