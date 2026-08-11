defmodule Norns.Workers.WorkerRegistryGardTest do
  use Norns.DataCase, async: false

  alias Norns.Workers.WorkerRegistry

  # Unique tenant ids per test keep the shared registry from cross-talking.
  defp tenant_id, do: System.unique_integer([:positive]) + 100_000

  defp tool_def(name), do: %{"name" => name, "description" => name, "input_schema" => %{}}

  describe "available_tools/2 gard filter" do
    test "strict equality: no-gard callers see no-gard tools, gard callers see their gard's" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "plain", self(), [tool_def("plain_tool")])
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("gard_tool")], gard: 42)

      assert [%{name: "plain_tool"}] = WorkerRegistry.available_tools(tid)
      assert [%{name: "gard_tool"}] = WorkerRegistry.available_tools(tid, gard: 42)
      assert [] = WorkerRegistry.available_tools(tid, gard: 99)

      WorkerRegistry.unregister_worker(tid, "plain")
      WorkerRegistry.unregister_worker(tid, "garded")
    end
  end

  describe "dispatch_task/4 gard strictness" do
    test "a gard-bound task never reaches a no-gard worker (it queues instead)" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "plain", self(), [tool_def("shared_tool")])

      {:ok, _} = WorkerRegistry.dispatch_task(tid, "shared_tool", %{}, from_pid: self(), gard: 42)
      refute_receive {:push_tool_task, _}, 100

      WorkerRegistry.unregister_worker(tid, "plain")
    end

    test "a no-gard task never reaches a gard-bound worker (no stolen dispatch)" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("shared_tool")], gard: 42)

      {:ok, _} = WorkerRegistry.dispatch_task(tid, "shared_tool", %{}, from_pid: self())
      refute_receive {:push_tool_task, _}, 100

      WorkerRegistry.unregister_worker(tid, "garded")
    end

    test "a gard-bound task reaches the matching gard worker" do
      tid = tenant_id()
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("shared_tool")], gard: 42)

      {:ok, task_id} = WorkerRegistry.dispatch_task(tid, "shared_tool", %{}, from_pid: self(), gard: 42)
      assert_receive {:push_tool_task, %{task_id: ^task_id}}, 500

      WorkerRegistry.unregister_worker(tid, "garded")
    end
  end

  describe "queued task flush is gard-aware" do
    test "a queued gard task waits for a matching-gard worker" do
      tid = tenant_id()

      # No worker yet — both tasks queue.
      {:ok, gard_task} = WorkerRegistry.dispatch_task(tid, "late_tool", %{}, from_pid: self(), gard: 42)
      {:ok, plain_task} = WorkerRegistry.dispatch_task(tid, "late_tool", %{}, from_pid: self())

      # A no-gard worker connects: only the no-gard task flushes to it.
      :ok = WorkerRegistry.register_worker(tid, "plain", self(), [tool_def("late_tool")])
      assert_receive {:push_tool_task, %{task_id: ^plain_task}}, 500
      refute_receive {:push_tool_task, _}, 100

      # The gard worker connects: the gard task flushes to it.
      :ok = WorkerRegistry.register_worker(tid, "garded", self(), [tool_def("late_tool")], gard: 42)
      assert_receive {:push_tool_task, %{task_id: ^gard_task}}, 500

      WorkerRegistry.unregister_worker(tid, "plain")
      WorkerRegistry.unregister_worker(tid, "garded")
    end
  end

  describe "LLM dispatch is not gard-filtered" do
    test "an LLM task reaches a gard-bound LLM worker" do
      tid = tenant_id()

      :ok =
        WorkerRegistry.register_worker(tid, "garded-llm", self(), [],
          capabilities: [:llm],
          gard: 42
        )

      {:ok, task_id} = WorkerRegistry.dispatch_llm_task(tid, %{model: "m"}, from_pid: self())
      assert_receive {:llm_task, %{task_id: ^task_id}}, 500

      WorkerRegistry.unregister_worker(tid, "garded-llm")
    end
  end

  describe "gard status follows the worker connection" do
    test "unregistering a gard worker marks the gard disconnected" do
      tenant = create_tenant()
      {:ok, gard} = Norns.Gards.create_gard(%{tenant_id: tenant.id, name: "g"})
      :ok = Norns.Gards.claim(tenant.id, gard.id, gard.claim_token)

      :ok = WorkerRegistry.register_worker(tenant.id, "gw", self(), [], gard: gard.id)
      WorkerRegistry.unregister_worker(tenant.id, "gw")
      Process.sleep(100)

      assert Norns.Gards.get_gard(tenant.id, gard.id).status == "disconnected"
    end
  end
end
